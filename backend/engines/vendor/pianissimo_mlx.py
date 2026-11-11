# Vendrad från https://huggingface.co/KlangAI/pianissimo-sv-mlx-8bit (revision 7b4d528bfb7ce3c66e2a187904f8d86ac39bc6de)
# Licens: CC BY 4.0, (c) Klang. Granskad och inbäddad så att ingen kod hämtas eller körs från modellrepot vid körning.
# Enda ändringen: relativ import av phrase_boost.
"""Klang Pianissimo on Apple silicon with parakeet-mlx: loads the quantized versions, computes NeMo's
audio features, splits long audio into chunks and supports phrase boosting.

    model = pianissimo_mlx.load("KlangAI/pianissimo-sv-mlx-8bit")
    print(pianissimo_mlx.transcribe(model, "audio.wav", boost=["Klang AI", "Pianissimo", "RixVox", "Common Voice"]).text)
"""
import json
import os
import shutil
import subprocess

import mlx.core as mx
import mlx.nn as nn
import numpy as np
from parakeet_mlx import tokenizer
from parakeet_mlx.alignment import (AlignedToken, merge_longest_common_subsequence, merge_longest_contiguous,
                                    sentences_to_result, tokens_to_sentences)
from parakeet_mlx.utils import from_config

from .phrase_boost import PhraseBoost

SAMPLE_RATE = 16000


def load(repo_or_path):
    """A Hugging Face repo id or a local directory with config.json and model.safetensors."""
    path = repo_or_path
    if not os.path.isdir(path):
        from huggingface_hub import snapshot_download
        path = snapshot_download(repo_or_path, allow_patterns=["config.json", "model.safetensors", "tokenizer.model"])
    cfg = json.load(open(os.path.join(path, "config.json")))
    model = from_config(cfg)
    q = cfg.get("quantization")
    if q:
        nn.quantize(model, group_size=q["group_size"], bits=q["bits"],
                    class_predicate=lambda p, m: isinstance(m, nn.Linear) and p.startswith("encoder.layers."))
    model.load_weights(os.path.join(path, "model.safetensors"))
    model.tokenizer_path = os.path.join(path, "tokenizer.model")
    return model


def read_audio(path):
    """Any format ffmpeg reads, as 16 kHz mono float32."""
    if shutil.which("ffmpeg") is None:
        raise RuntimeError("reading audio files needs ffmpeg (brew install ffmpeg), or pass a 16 kHz numpy array")
    out = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-f", "s16le", "-ac", "1",
                          "-ar", str(SAMPLE_RATE), "-"], capture_output=True, check=True).stdout
    return np.frombuffer(out, np.int16).astype(np.float32) / 32768.0


def features(audio, args):
    """NeMo's log-mel featurizer, ported to MLX."""
    n_fft, win = args.n_fft, int(args.window_size * args.sample_rate)
    hop = int(args.window_stride * args.sample_rate)
    x = mx.concatenate([audio[:1], audio[1:] - 0.97 * audio[:-1]])
    x = mx.pad(x, [(n_fft // 2, n_fft // 2)])
    frames = mx.as_strided(x, shape=((x.shape[0] - n_fft) // hop + 1, n_fft), strides=(hop, 1))
    window = mx.array(np.pad(np.hanning(win), (n_fft - win) // 2).astype(np.float32))
    power = mx.abs(mx.fft.rfft(frames * window)) ** 2
    logmel = mx.log(mx.matmul(power, args._filterbanks.T.astype(mx.float32)) + 2 ** -24)
    valid = audio.shape[0] // hop
    logmel = logmel[:valid]
    mean = logmel.mean(axis=0, keepdims=True)
    std = mx.sqrt(((logmel - mean) ** 2).sum(axis=0, keepdims=True) / (valid - 1))
    return mx.expand_dims((logmel - mean) / (std + 1e-5), 0)


def transcribe(model, audio, chunk_duration=120.0, overlap_duration=15.0, boost=None, boost_alpha=1.0):
    """audio is a path or a 16 kHz mono numpy array. Audio longer than chunk_duration seconds is
    transcribed in overlapping chunks (None for one pass). boost lists phrases to spell as written."""
    if isinstance(audio, (str, os.PathLike)):
        audio = read_audio(audio)
    audio = np.asarray(audio, dtype=np.float32)
    tree = PhraseBoost(boost, model.tokenizer_path, vocab_size=len(model.vocabulary)) if boost else None
    if chunk_duration is None or len(audio) <= chunk_duration * SAMPLE_RATE:
        return _transcribe_piece(model, audio, tree, boost_alpha)

    step = int((chunk_duration - overlap_duration) * SAMPLE_RATE)
    size = int(chunk_duration * SAMPLE_RATE)
    tokens = []
    for start in range(0, len(audio), step):
        result = _transcribe_piece(model, audio[start:start + size], tree, boost_alpha)
        offset = start / SAMPLE_RATE
        for sentence in result.sentences:
            for token in sentence.tokens:
                token.start += offset
                token.end = token.start + token.duration
        if not tokens:
            tokens = result.tokens
        else:
            try:
                tokens = merge_longest_contiguous(tokens, result.tokens, overlap_duration=overlap_duration)
            except RuntimeError:
                tokens = merge_longest_common_subsequence(tokens, result.tokens, overlap_duration=overlap_duration)
        mx.clear_cache()
        if start + size >= len(audio):
            break
    return sentences_to_result(tokens_to_sentences(tokens))


def _transcribe_piece(model, audio, tree, alpha):
    mel = features(mx.array(audio), model.preprocessor_config)
    if tree is None:
        return model.generate(mel)[0]
    encoded, lengths = model.encoder(mel)
    mx.eval(encoded, lengths)
    return sentences_to_result(tokens_to_sentences(_boosted_greedy(model, encoded, int(lengths[0]), tree, alpha)))


def _boosted_greedy(model, encoded, length, tree, alpha):
    """parakeet-mlx's greedy TDT decoding with the phrase bonus added."""
    blank = len(model.vocabulary)
    hypothesis, last_token, hidden_state = [], None, None
    boost_state, step, new_symbols = 0, 0, 0
    while step < length:
        decoder_out, (hidden, cell) = model.decoder(
            mx.array([[last_token]]) if last_token is not None else None, hidden_state)
        decoder_out = decoder_out.astype(encoded.dtype)
        decoder_hidden = (hidden.astype(encoded.dtype), cell.astype(encoded.dtype))
        joint_out = model.joint(encoded[:, step:step + 1], decoder_out)

        token_logits = joint_out[0, 0, :, :blank + 1]
        pred_token = int(mx.argmax(token_logits))
        token_probs = mx.softmax(token_logits, axis=-1)
        entropy = -mx.sum(token_probs * mx.log(token_probs + 1e-10), axis=-1)
        confidence = float(1.0 - entropy / mx.log(mx.array(blank + 1, dtype=token_probs.dtype)))
        decision = int(mx.argmax(joint_out[0, 0, :, blank + 1:]))

        if pred_token != blank:
            bonus, next_states = tree.scores(boost_state)
            logits = np.array(token_logits[0, :blank].astype(mx.float32))
            pred_token = int(np.argmax(logits + alpha * bonus))
            boost_state = int(next_states[pred_token])
            hypothesis.append(AlignedToken(
                pred_token, start=step * model.time_ratio, duration=model.durations[decision] * model.time_ratio,
                confidence=confidence, text=tokenizer.decode([pred_token], model.vocabulary)))
            last_token = pred_token
            hidden_state = decoder_hidden

        step += model.durations[decision]
        new_symbols += 1
        if model.durations[decision] != 0:
            new_symbols = 0
        elif model.max_symbols is not None and model.max_symbols <= new_symbols:
            step += 1
            new_symbols = 0
    return hypothesis
