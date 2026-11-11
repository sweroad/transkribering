"""Exempel på en alternativ motor: Whisper-modeller i MLX-format (t.ex. mlx-community/whisper-*).

Kräver paketet mlx-whisper (avkommentera i requirements.txt och kör scripts/setup_backend.sh).
Visar hur en ny modellfamilj kopplas in utan ändringar i Swift-appen.
"""
from __future__ import annotations

import numpy as np

from .base import Engine, download_snapshot


class MLXWhisperEngine(Engine):
    name = "mlx-whisper"

    def load(self) -> None:
        try:
            import mlx_whisper
        except ImportError as exc:
            raise RuntimeError("Motorn mlx-whisper kräver paketet mlx-whisper. "
                               "Avkommentera det i backend/requirements.txt och installera om backend.") from exc
        self._mlx_whisper = mlx_whisper
        self._path = download_snapshot(self.spec["repo"], self.spec.get("revision"), None, self.status)
        self.status("Laddar modellen…")

    def transcribe(self, audio: np.ndarray, vocabulary: list[str] | None = None) -> str:
        options = self.spec.get("options") or {}
        prompt = ", ".join(v for v in (vocabulary or []) if v.strip()) or None
        result = self._mlx_whisper.transcribe(
            np.asarray(audio, dtype=np.float32),
            path_or_hf_repo=self._path,
            language=self.spec.get("language"),
            initial_prompt=prompt,
            **options,
        )
        return result.get("text", "").strip()
