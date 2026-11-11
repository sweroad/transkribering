"""Bakgrundsprocess som Transkribering-appen startar för att transkribera lokalt.

Protokoll: en JSON-rad per meddelande på stdin/stdout. Loggar skrivs till stderr.

Förfrågningar (från appen):
  {"id": 1, "cmd": "load", "model": {...post ur models.json...}}
  {"id": 2, "cmd": "transcribe", "audio_path": "/tmp/x.f32", "vocabulary": ["Knowit"], "context_seconds": 3.0}
      audio_path pekar på rå float32 little-endian, 16 kHz mono. Valfritt context_seconds: så många
      sekunder i början är tidigare ljud som bara ger sammanhang; bara texten efter returneras.
  {"id": 3, "cmd": "ping"}
  {"id": 4, "cmd": "shutdown"}

Svar:       {"id": 1, "ok": true, ...}  eller  {"id": 1, "ok": false, "error": "..."}
Händelser:  {"event": "status", "message": "..."}
"""
from __future__ import annotations

import json
import os
import sys
import time
import traceback

# Gör så att paketet engines kan importeras oavsett arbetskatalog
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# stdout är reserverat för protokollet; allt annat (t.ex. utskrifter från bibliotek) går till stderr.
_protocol_out = sys.stdout
sys.stdout = sys.stderr

import numpy as np  # noqa: E402

from engines import engine_class  # noqa: E402
from engines.base import SAMPLE_RATE  # noqa: E402


def send(message: dict) -> None:
    _protocol_out.write(json.dumps(message, ensure_ascii=False) + "\n")
    _protocol_out.flush()


def log(*args) -> None:
    print("[worker]", *args, file=sys.stderr, flush=True)


def status(message: str) -> None:
    log(message)
    send({"event": "status", "message": message})


class Worker:
    def __init__(self):
        self.engine = None
        self.model_id = None

    def handle(self, req: dict) -> dict:
        cmd = req.get("cmd")
        if cmd == "ping":
            return {"model": self.model_id}
        if cmd == "load":
            return self.load(req["model"])
        if cmd == "transcribe":
            return self.transcribe(req)
        raise ValueError(f"Okänt kommando: {cmd}")

    def load(self, spec: dict) -> dict:
        if self.model_id == spec.get("id") and self.engine is not None:
            return {"model": self.model_id, "cached": True}
        if self.engine is not None:
            self.engine.unload()
            self.engine = None
            self.model_id = None
        started = time.time()
        engine = engine_class(spec["engine"])(spec, status)
        engine.load()
        status("Värmer upp modellen…")
        engine.warmup()
        self.engine, self.model_id = engine, spec.get("id")
        log(f"Modell {self.model_id} klar på {time.time() - started:.1f} s")
        return {"model": self.model_id}

    def transcribe(self, req: dict) -> dict:
        if self.engine is None:
            raise RuntimeError("Ingen modell är laddad")
        path = req["audio_path"]
        audio = np.fromfile(path, dtype="<f4")
        if req.get("sample_rate", SAMPLE_RATE) != SAMPLE_RATE:
            raise ValueError(f"Ljudet måste vara {SAMPLE_RATE} Hz")
        started = time.time()
        context = float(req.get("context_seconds") or 0.0)
        if context > 0:
            text = self.engine.transcribe_with_context(audio, context, req.get("vocabulary") or None)
        else:
            text = self.engine.transcribe(audio, req.get("vocabulary") or None)
        elapsed = time.time() - started
        log(f"Transkriberade {len(audio) / SAMPLE_RATE - context:.1f} s ljud "
            f"(+{context:.1f} s kontext) på {elapsed:.2f} s")
        return {"text": text, "seconds": elapsed}


def main() -> None:
    worker = Worker()
    send({"event": "ready"})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            log("Ogiltig JSON:", exc)
            continue
        req_id = req.get("id")
        if req.get("cmd") == "shutdown":
            send({"id": req_id, "ok": True})
            break
        try:
            result = worker.handle(req)
            send({"id": req_id, "ok": True, **result})
        except Exception as exc:  # noqa: BLE001
            log(traceback.format_exc())
            send({"id": req_id, "ok": False, "error": str(exc)})


if __name__ == "__main__":
    main()
