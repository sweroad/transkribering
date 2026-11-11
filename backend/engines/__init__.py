"""Register över transkriberingsmotorer. Nyckeln matchar fältet "engine" i models.json.

Modulerna importeras först när motorn används, så att valfria beroenden (t.ex. mlx-whisper)
bara behövs om man faktiskt väljer en sådan modell.
"""
from __future__ import annotations

import importlib

from .base import Engine

ENGINES: dict[str, tuple[str, str]] = {
    "pianissimo-mlx": (".pianissimo_mlx", "PianissimoMLXEngine"),
    "mlx-whisper": (".mlx_whisper", "MLXWhisperEngine"),
}


def engine_class(name: str) -> type[Engine]:
    if name not in ENGINES:
        raise ValueError(f"Okänd motor '{name}'. Tillgängliga: {', '.join(sorted(ENGINES))}")
    module_name, class_name = ENGINES[name]
    module = importlib.import_module(module_name, __name__)
    return getattr(module, class_name)
