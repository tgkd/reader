import sys

from faster_whisper import WhisperModel

wav, t0, t1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
offset = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
model = WhisperModel("large-v3", device="cpu", compute_type="int8")
segs, _ = model.transcribe(wav, language="ja", beam_size=5, temperature=0.0,
                           word_timestamps=True, condition_on_previous_text=False)
for s in segs:
    for w in s.words:
        if t0 <= w.start + offset <= t1:
            print(f"{w.start + offset:8.2f}-{w.end + offset:8.2f} {w.word}")
