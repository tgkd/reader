import array
import math
import subprocess
import sys

from alignment_io import is_word, load

mp3, align = sys.argv[1], sys.argv[2]
chars, starts, ends = load(align)
raw = subprocess.run(
    ["/opt/homebrew/bin/ffmpeg", "-v", "error", "-i", mp3, "-ac", "1", "-ar", "16000",
     "-f", "s16le", "-"], capture_output=True).stdout
pcm = array.array("h")
pcm.frombytes(raw[: len(raw) // 2 * 2])
hop = 320
frames = len(pcm) // hop
rms = [
    20 * math.log10(max(math.sqrt(sum(x * x for x in pcm[i * hop:(i + 1) * hop]) / hop) / 32768, 1e-6))
    for i in range(frames)
]
audio = [1 if v > -35 else 0 for v in rms]
pred = [0] * frames
for c, s, e in zip(chars, starts, ends):
    if not is_word(c):
        continue
    for f in range(int(s / 0.02), min(frames, int(e / 0.02) + 1)):
        pred[f] = 1


def best_lag(w0, w1):
    best = None
    for lag in range(-150, 151):
        agree = 0
        count = 0
        for f in range(w0, w1):
            g = f + lag
            if 0 <= g < frames:
                agree += 1 if pred[f] == audio[g] else 0
                count += 1
        v = agree / max(count, 1)
        if best is None or v > best[0]:
            best = (v, lag)
    return best


window = int(20 / 0.02)
print("window(s)    lag(audio-align, s)  agreement")
for w0 in range(0, frames - window, window):
    v, lag = best_lag(w0, w0 + window)
    print(f"{w0 * 0.02:6.0f}-{(w0 + window) * 0.02:4.0f}   {lag * 0.02:+6.2f}   {v:.2f}")
