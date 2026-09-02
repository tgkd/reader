import json
import math
import sys

from alignment_io import is_word, load

PAUSE_MIN = 0.5
HOSTS = set("。、！？!?」』）\n")


def pauses(chars, starts, ends):
    out = []
    i = 0
    n = len(chars)
    while i < n:
        if ends[i] - starts[i] >= PAUSE_MIN:
            j = i
            while j + 1 < n and ends[j + 1] - starts[j + 1] >= PAUSE_MIN:
                j += 1
            out.append((i, j, starts[i], ends[j]))
            i = j + 1
        else:
            i += 1
    return out


def hosts(chars):
    return [i for i, c in enumerate(chars) if c in HOSTS]


def speech_count(chars, a, b):
    return sum(1 for k in range(a, b) if is_word(chars[k]))


def assign(chars, starts, ends, ps, hs):
    if not ps or not hs:
        return {}
    total_speech = speech_count(chars, 0, len(chars))
    pause_time = sum(p[3] - p[2] for p in ps)
    rate = total_speech / max(ends[-1] - pause_time, 1e-6)
    INF = float("inf")
    K = len(ps)
    H = len(hs)
    WINDOW = 40

    def seg_cost(prev_host, prev_end, host, start):
        a = prev_host + 1 if prev_host is not None else 0
        n = speech_count(chars, a, host)
        dt = start - prev_end
        if dt <= 0:
            return INF if n > 0 else 0.0
        expected = rate * dt
        return abs(n - expected) / max(rate, 1e-6)

    best = [dict() for _ in range(K + 1)]
    best[0][(-1, 0.0)] = (0.0, None)
    for k in range(K):
        i0, i1, t0, t1 = ps[k]
        drop_cost = (t1 - t0) * 2.0
        for (ph, pe), (c, _) in best[k].items():
            key = (ph, pe)
            cur = best[k + 1].get(key)
            if cur is None or c + drop_cost < cur[0]:
                best[k + 1][key] = (c + drop_cost, (ph, pe, k, None))
            for h in hs:
                if h <= ph or abs(h - i0) > WINDOW:
                    continue
                sc = seg_cost(ph if ph >= 0 else None, pe, h, t0)
                if sc == INF:
                    continue
                key2 = (h, t1)
                cand = c + sc
                cur2 = best[k + 1].get(key2)
                if cur2 is None or cand < cur2[0]:
                    best[k + 1][key2] = (cand, (ph, pe, k, h))
    tail = None
    for (ph, pe), (c, back) in best[K].items():
        n = speech_count(chars, ph + 1, len(chars))
        dt = ends[-1] - pe
        c2 = c + (abs(n - rate * dt) / rate if dt > 0 else 0)
        if tail is None or c2 < tail[0]:
            tail = (c2, (ph, pe))
    mapping = {}
    state = tail[1]
    for k in range(K, 0, -1):
        c, back = best[k][state]
        ph, pe, kk, h = back
        if h is not None:
            mapping[kk] = h
        state = (ph, pe)
    return mapping


def retime(chars, starts, ends, ps, mapping):
    n = len(chars)
    ns = [None] * n
    ne = [None] * n
    fixed = []
    for k, (i0, i1, t0, t1) in enumerate(ps):
        h = mapping.get(k)
        if h is None:
            continue
        fixed.append((h, t0, t1, i0, i1))
    fixed.sort()
    for h, t0, t1, i0, i1 in fixed:
        ns[h] = t0
        ne[h] = t1
    anchors = [(-1, 0.0, 0.0, -1, -1)] + fixed + [(n, ends[-1], ends[-1], n, n)]
    for (ha, _, ta, ia0, ia1), (hb, tb, _, ib0, ib1) in zip(anchors, anchors[1:]):
        lo, hi = ha + 1, hb
        if lo >= hi:
            continue
        src_lo, src_hi = ia1 + 1, ib0
        src = [(starts[k], ends[k]) for k in range(max(src_lo, 0), min(src_hi, n))]
        span = tb - ta
        if not src or src[-1][1] - src[0][0] <= 0 or span <= 0:
            m = hi - lo
            for j, k in enumerate(range(lo, hi)):
                ns[k] = ta + span * j / m
                ne[k] = ta + span * (j + 1) / m
            continue
        s0 = src[0][0]
        s1 = src[-1][1]
        m = hi - lo
        for j, k in enumerate(range(lo, hi)):
            u0 = j / m
            u1 = (j + 1) / m
            def src_at(u):
                pos = u * len(src)
                idx = min(int(pos), len(src) - 1)
                frac = pos - idx
                a, b = src[idx]
                return a + (b - a) * frac
            ns[k] = ta + (src_at(u0) - s0) / (s1 - s0) * span
            ne[k] = ta + (src_at(u1) - s0) / (s1 - s0) * span
    for k in range(n):
        if ns[k] is None:
            ns[k] = starts[k]
            ne[k] = ends[k]
    for k in range(1, n):
        if ns[k] < ns[k - 1]:
            ns[k] = ns[k - 1]
        if ne[k] < ns[k]:
            ne[k] = ns[k]
    return ns, ne


def relabel(chars, starts, ends):
    ps = pauses(chars, starts, ends)
    hs = hosts(chars)
    mapping = assign(chars, starts, ends, ps, hs)
    moved = sum(1 for k, h in mapping.items() if not (ps[k][0] <= h <= ps[k][1]))
    ns, ne = retime(chars, starts, ends, ps, mapping)
    return ns, ne, {"pauses": len(ps), "assigned": len(mapping), "moved": moved}


if __name__ == "__main__":
    chars, starts, ends = load(sys.argv[1])
    ns, ne, info = relabel(chars, starts, ends)
    print(json.dumps(info))
    if len(sys.argv) > 2:
        json.dump({"characters": chars, "character_start_times_seconds": ns,
                   "character_end_times_seconds": ne}, open(sys.argv[2], "w"), ensure_ascii=False)
