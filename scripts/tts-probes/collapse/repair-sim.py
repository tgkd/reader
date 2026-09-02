import json
import os
import sys

from alignment_io import collapsed_runs, load, terminal_plateau

mp3, align = sys.argv[1], sys.argv[2]
anchors = json.load(open(sys.argv[3])) if len(sys.argv) > 3 else {}
chars, starts, ends = load(align)
audio = os.path.getsize(mp3) / 16000
delta = audio - ends[-1]
n = len(chars)
stop = n - terminal_plateau(ends)
runs = collapsed_runs(chars, starts, ends, stop=stop)
print(f"audio={audio:.3f} alignEnd={ends[-1]:.3f} delta={delta:+.3f} terminalPlateau={n - stop}")
print("runs:", [(i, j - i, "".join(chars[i:j])) for i, j in runs])

new_starts, new_ends = starts[:], ends[:]
total = sum(j - i for i, j in runs)
shift = 0.0
if runs and delta > 0:
    for i, j in runs:
        add = delta * (j - i) / total
        per = add / (j - i)
        for k in range(i, j):
            new_starts[k] = starts[k] + shift + per * (k - i)
            new_ends[k] = starts[k] + shift + per * (k - i + 1)
        shift += add
        for k in range(j, n):
            new_starts[k] = starts[k] + shift
            new_ends[k] = ends[k] + shift
print(f"repaired alignEnd={new_ends[-1]:.3f}")
if anchors:
    print("char   before   after  (align - whisper)")
    for c, w in sorted((int(k), v) for k, v in anchors.items()):
        print(f"{c:5d}  {starts[c] - w:+6.2f}  {new_starts[c] - w:+6.2f}")
