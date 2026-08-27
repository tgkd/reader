#!/usr/bin/env python3
"""Transcribe every arm of a ruby-loss demo and score the arms against each other.

    uv run --with faster-whisper python scripts/tts-probes/transcribe-arms.py <demo-dir> <wav-dir>

Whisper is used as a DIFFERENTIAL instrument, not as ground truth: the same model on
three clips of one sentence mistakes them the same way, so a difference between the
transcripts is evidence about pronunciation even when no transcript is correct.
"""
import json
import pathlib
import subprocess
import sys

from faster_whisper import WhisperModel

ROOT = pathlib.Path(sys.argv[1])
WAV = pathlib.Path(sys.argv[2])
WAV.mkdir(parents=True, exist_ok=True)
MODEL = sys.argv[3] if len(sys.argv) > 3 else "large-v3"
KANA_PROMPT = "ひらがなだけでかいてください。ぜんぶひらがなです。"

data = json.load(open(ROOT / "cases.json", encoding="utf-8"))
model = WhisperModel(MODEL, device="cpu", compute_type="int8")


def wav_for(case_id, arm, mp3):
    out = WAV / f"{case_id}-{arm}.wav"
    if not out.exists():
        subprocess.run(
            ["/opt/homebrew/bin/ffmpeg", "-y", "-v", "error", "-i", str(mp3),
             "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(out)],
            check=True)
    return out


def transcribe(path, prompt):
    segs, _ = model.transcribe(str(path), language="ja", initial_prompt=prompt,
                               beam_size=5, temperature=0.0,
                               condition_on_previous_text=False)
    return "".join(s.text for s in segs).strip()


out = []
for case in data["results"]:
    row = {"id": case["id"], "surface": case["surface"],
           "bookReading": case["bookReading"], "sentence": case["sentence"],
           "base": (case.get("contextual") or {}).get("base"),
           "baseReading": (case.get("contextual") or {}).get("baseReading"),
           "arms": {}}
    for arm, spec in case["arms"].items():
        if "error" in spec:
            continue
        path = wav_for(case["id"], arm, ROOT / spec["file"])
        row["arms"][arm] = {
            "plain": transcribe(path, None),
            "kana": transcribe(path, KANA_PROMPT),
        }
    out.append(row)
    print(f'{case["id"]} {case["surface"]}→{case["bookReading"]}', flush=True)
    for arm, t in row["arms"].items():
        print(f'    {arm:5} {t["plain"]}', flush=True)
        print(f'    {arm:5} {t["kana"]}   [kana]', flush=True)

json.dump({"model": MODEL, "cases": out}, open(ROOT / "transcripts.json", "w",
                                               encoding="utf-8"),
          ensure_ascii=False, indent=2)
print(f"\nwrote {ROOT}/transcripts.json ({len(out)} cases)")
