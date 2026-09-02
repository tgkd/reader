import json


def load(path):
    a = json.load(open(path, encoding="utf-8"))
    a = a.get("alignment", a)
    chars = a["characters"]
    ends = a.get("ends") or a["character_end_times_seconds"]
    starts = a.get("starts") or a.get("character_start_times_seconds") or ([0.0] + ends[:-1])
    return chars, list(starts), list(ends)


def is_word(c):
    import unicodedata
    return c.strip() != "" and unicodedata.category(c)[0] in "LN"


def collapsed_runs(chars, starts, ends, min_len=8, max_dur=0.02, stop=None):
    n = len(chars) if stop is None else stop
    runs = []
    i = 0
    while i < n:
        if is_word(chars[i]) and ends[i] - starts[i] <= max_dur:
            j = i
            while j < n and is_word(chars[j]) and ends[j] - starts[j] <= max_dur:
                j += 1
            if j - i >= min_len:
                runs.append((i, j))
            i = j
        else:
            i += 1
    return runs


def terminal_plateau(ends):
    k = len(ends)
    while k > 0 and ends[k - 1] <= (ends[k - 2] if k >= 2 else 0) + 1e-9:
        k -= 1
    return len(ends) - k
