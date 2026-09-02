import difflib
import json
import statistics
import sys

import os

from alignment_io import collapsed_runs, load, terminal_plateau
from relabel import relabel


def repair_collapse(chars, starts, ends, audio_seconds):
    delta = audio_seconds - ends[-1]
    n = len(chars)
    runs = collapsed_runs(chars, starts, ends, stop=n - terminal_plateau(ends))
    if delta < 0.3 or not runs:
        return starts[:], ends[:]
    ns, ne = starts[:], ends[:]
    total = sum(j - i for i, j in runs)
    shift = 0.0
    for i, j in runs:
        add = delta * (j - i) / total
        per = add / (j - i)
        for k in range(i, j):
            ns[k] = starts[k] + shift + per * (k - i)
            ne[k] = starts[k] + shift + per * (k - i + 1)
        shift += add
        for k in range(j, n):
            ns[k] = starts[k] + shift
            ne[k] = ends[k] + shift
    return ns, ne


def anchors(chars, starts, words):
    text = "".join(chars)
    wtext = "".join(w for w, _, _ in words)
    first = []
    p = 0
    for w, _, _ in words:
        first.append(p)
        p += len(w)
    sm = difflib.SequenceMatcher(None, wtext, text, autojunk=False)
    out = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag != "equal" or i2 - i1 < 4:
            continue
        for wi, (w, s, e) in enumerate(words):
            f = first[wi]
            if i1 <= f and f + len(w) <= i2 and len(w) >= 2:
                out.append((j1 + (f - i1), s))
    return out


def buckets(pairs, starts):
    b = {}
    for c, s in pairs:
        b.setdefault(int(s // 30), []).append(starts[c] - s)
    return " ".join(f"{statistics.median(v):+.2f}" for k, v in sorted(b.items()))


def summary(pairs, starts):
    leads = [starts[c] - s for c, s in pairs]
    absd = sorted(abs(l - 0.15) for l in leads)
    return (f"median {statistics.median(leads):+.2f}  p90|err| {absd[len(absd) * 9 // 10]:.2f}  "
            f"max|err| {absd[-1]:.2f}")


for path in sys.argv[1:]:
    chars, starts, ends = load(path)
    words = json.load(open(path.replace(".alignment.json", ".whisper-words.json")))
    pairs = anchors(chars, starts, words)
    audio = os.path.getsize(path.replace(".alignment.json", ".mp3")) / 16000
    rs, re_ = repair_collapse(chars, starts, ends, audio)
    ns, ne, info = relabel(chars, rs, re_)
    print(f"== {path.split('/')[-1]}  anchors={len(pairs)}  {info}")
    print(f"   before:           {summary(pairs, starts)}")
    print(f"                     {buckets(pairs, starts)}")
    print(f"   collapse repair:  {summary(pairs, rs)}")
    print(f"                     {buckets(pairs, rs)}")
    print(f"   + relabel:        {summary(pairs, ns)}")
    print(f"                     {buckets(pairs, ns)}")


def forced_starts(chars, forced_path):
    import difflib
    j = json.load(open(forced_path))
    fc = [c["text"] for c in j["characters"]]
    fs = [c["start"] for c in j["characters"]]
    if fc == chars:
        return fs
    sm = difflib.SequenceMatcher(None, "".join(fc), "".join(chars), autojunk=False)
    out = [None] * len(chars)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            for k in range(i2 - i1):
                out[j1 + k] = fs[i1 + k]
    last = 0.0
    for k in range(len(out)):
        if out[k] is None:
            out[k] = last
        last = out[k]
    return out


if __name__ == "__main__" and any(p.endswith(".alignment.json") for p in sys.argv[1:]):
    for path in sys.argv[1:]:
        forced = path.replace(".alignment.json", ".forced.json")
        if not os.path.exists(forced):
            continue
        chars, starts, ends = load(path)
        words = json.load(open(path.replace(".alignment.json", ".whisper-words.json")))
        pairs = anchors(chars, starts, words)
        fs = forced_starts(chars, forced)
        j = json.load(open(forced))
        print(f"== {path.split('/')[-1]}  forced alignment  loss={j.get('loss')}  "
              f"chars={len(j['characters'])}/{len(chars)}")
        print(f"   forced:           {summary(pairs, fs)}")
        print(f"                     {buckets(pairs, fs)}")
