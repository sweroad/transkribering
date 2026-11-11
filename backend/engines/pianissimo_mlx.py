"""Motor för Klang Pianissimo (Parakeet TDT, FastConformer) på Apple silicon via MLX.

Använder Klangs laddare (inbäddad i engines/vendor), eftersom den kan läsa de kvantiserade
versionerna och förbehandlar ljudet exakt som vid träningen. Från modellrepot hämtas bara
vikter, konfiguration och tokenizer – ingen kod. Fungerar för alla repon med samma upplägg,
t.ex. KlangAI/pianissimo-da-mlx-8bit.
"""
from __future__ import annotations

import numpy as np

from .base import Engine, download_snapshot

FILES = ["config.json", "model.safetensors", "tokenizer.model"]


class PianissimoMLXEngine(Engine):
    name = "pianissimo-mlx"

    def load(self) -> None:
        from .vendor import pianissimo_mlx

        path = download_snapshot(self.spec["repo"], self.spec.get("revision"), FILES, self.status)
        self.status("Laddar modellen…")
        self._lib = pianissimo_mlx
        self._model = pianissimo_mlx.load(path)

    supports_context = True

    def _run(self, audio: np.ndarray, vocabulary: list[str] | None):
        options = self.spec.get("options") or {}
        return self._lib.transcribe(
            self._model,
            np.asarray(audio, dtype=np.float32),
            chunk_duration=options.get("chunk_duration", 120.0),
            boost=[v for v in (vocabulary or []) if v.strip()] or None,
            boost_alpha=options.get("boost_alpha", 1.0),
        )

    def transcribe(self, audio: np.ndarray, vocabulary: list[str] | None = None) -> str:
        return self._run(audio, vocabulary).text.strip()

    def transcribe_with_context(self, audio: np.ndarray, context_seconds: float,
                                vocabulary: list[str] | None = None) -> str:
        if context_seconds <= 0:
            return self.transcribe(audio, vocabulary)
        tokens = [t for s in self._run(audio, vocabulary).sentences for t in s.tokens]
        # Behåll tokens från första ordet som börjar efter kontexten. Skiljetecken direkt efter
        # gränsen hör till föregående fras (modellen tidsstämplar dem en bit efter ordet).
        tolerance = 0.08
        start = next((i for i, t in enumerate(tokens)
                      if t.start >= context_seconds - tolerance and t.text.startswith(" ")), None)
        if start is None:
            start = next((i for i, t in enumerate(tokens)
                          if t.start >= context_seconds - tolerance and any(c.isalnum() for c in t.text)), None)
        if start is None:
            return ""
        return "".join(t.text for t in tokens[start:]).strip()

    def unload(self) -> None:
        self._model = None
        try:
            import mlx.core as mx
            mx.clear_cache()
        except Exception:
            pass
