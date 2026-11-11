"""Gränssnitt för transkriberingsmotorer.

En motor laddar en modell utifrån en modellspecifikation (en post i models.json) och
transkriberar 16 kHz mono float32-ljud till text. Lägg till en ny motor genom att skapa en
modul i detta paket med en klass som ärver Engine och registrera den i engines/__init__.py.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any, Callable

import numpy as np

SAMPLE_RATE = 16000

StatusCallback = Callable[[str], None]


class Engine(ABC):
    #: Namnet som används i fältet "engine" i models.json
    name: str = ""
    #: True om motorn kan använda föregående ljud som kontext (se transcribe_with_context).
    supports_context: bool = False

    def __init__(self, spec: dict[str, Any], status: StatusCallback):
        self.spec = spec
        self.status = status

    @abstractmethod
    def load(self) -> None:
        """Ladda ner (vid behov) och ladda modellen i minnet."""

    @abstractmethod
    def transcribe(self, audio: np.ndarray, vocabulary: list[str] | None = None) -> str:
        """audio: 16 kHz mono float32. vocabulary: ord/namn som modellen bör stava som de är skrivna."""

    def transcribe_with_context(self, audio: np.ndarray, context_seconds: float,
                                vocabulary: list[str] | None = None) -> str:
        """Transkriberar en fras där de första `context_seconds` sekunderna är tidigare ljud som bara
        ska ge modellen sammanhang. Returnerar endast texten för frasen efter kontexten.
        Standard: motorer utan stöd ignorerar kontexten."""
        start = int(max(0.0, context_seconds) * SAMPLE_RATE)
        return self.transcribe(audio[start:], vocabulary)

    def warmup(self) -> None:
        """Kör en kort tyst inferens så att första riktiga transkriberingen går snabbt."""
        try:
            self.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32))
        except Exception:
            pass

    def unload(self) -> None:
        """Frigör resurser (valfritt)."""


def download_snapshot(repo: str, revision: str | None, allow_patterns: list[str] | None,
                      status: StatusCallback) -> str:
    """Hämtar en modell från Hugging Face till den lokala cachen. Använder cachen direkt om
    modellen redan finns, så att inget nätverk behövs efter första nedladdningen."""
    from huggingface_hub import snapshot_download

    try:
        return snapshot_download(repo, revision=revision, allow_patterns=allow_patterns, local_files_only=True)
    except Exception:
        status(f"Laddar ner {repo} (endast första gången)…")
        return snapshot_download(repo, revision=revision, allow_patterns=allow_patterns)
