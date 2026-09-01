import json, math, pathlib, re, subprocess, sys, array

OUT = pathlib.Path('/Users/paveltrofimov/Projects/j/reader/scripts/tts-probes/out/2026-09-01-truncation')
BPS = 16000.0
TAIL_DB = -35.0

def ffprobe(p):
    r = subprocess.run(['/opt/homebrew/bin/ffprobe','-v','error','-show_entries','format=duration','-of','csv=p=0',str(p)],
                       capture_output=True, text=True)
    return float(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip() else None

def tail_envelope(p, seconds=2.0, dur=None):
    dur = dur or ffprobe(p) or 0
    start = max(0.0, dur - seconds)
    r = subprocess.run(['/opt/homebrew/bin/ffmpeg','-v','error','-ss',f'{start}','-i',str(p),'-ac','1','-ar','8000',
                        '-f','s16le','-'], capture_output=True)
    d = array.array('h'); d.frombytes(r.stdout)
    sr, win = 8000, 800
    out = []
    for i in range(0, max(0, len(d)-win), win):
        w = d[i:i+win]
        rms = math.sqrt(sum(x*x for x in w)/len(w))
        out.append((start + i/sr, 20*math.log10(rms/32768) if rms > 0 else -99.0))
    return out

def cram_profile(ends):
    if len(ends) < 40: return None
    durs = [ends[i] - (ends[i-1] if i else 0.0) for i in range(len(ends))]
    s = sorted(d for d in durs if d >= 0)
    median = s[len(s)//2]
    q = len(durs)//4
    last_q = durs[-q:]
    return {'median': round(median,4),
            'last_quarter_mean': round(sum(last_q)/len(last_q), 4),
            'ratio': round((sum(last_q)/len(last_q))/median, 3) if median > 0 else None,
            'zero_run_at_end': next((i for i,d in enumerate(reversed(durs)) if d > median/4), 0)}

def final_sentence(text):
    parts = [p for p in re.split(r'(?<=[。！？!?])', text.strip()) if p.strip()]
    return parts[-1].strip() if parts else text[-40:].strip()

rows = []
for mp3 in sorted(OUT.glob('*.mp3')):
    name = mp3.stem
    sub = (OUT/f'{name}.txt')
    al = (OUT/f'{name}.alignment.json')
    if not sub.exists() or not al.exists():
        print(f'{name}: missing artifacts, skipped'); continue
    text = sub.read_text()
    a = json.loads(al.read_text())
    ends = a['ends']
    n = len(text)
    byt = mp3.stat().st_size
    est = byt / BPS
    true = ffprobe(mp3)
    align_end = ends[-1] if ends else 0.0
    env = tail_envelope(mp3, 2.0, true)
    last_db = env[-1][1] if env else None
    tail = (OUT/f'{name}.tail.txt')
    fs = final_sentence(text)
    heard = tail.read_text().strip() if tail.exists() else None
    rows.append({
        'name': name, 'chars': n, 'labels': len(a['characters']),
        'join_ok': ''.join(a['characters']) == text,
        'bytes': byt, 'audio_est_s': round(est,3), 'audio_true_s': round(true,3) if true else None,
        'align_end_s': round(align_end,3), 'residual_s': round(est - align_end,3),
        'guard_pass': abs(est - align_end) <= 1.0,
        'apparent_chars_per_s': round(n/est,3) if est else None,
        'tail_last_100ms_db': round(last_db,1) if last_db is not None else None,
        'ends_mid_word': (last_db is not None and last_db > TAIL_DB),
        'cram': cram_profile(ends),
        'final_sentence': fs, 'tail_transcript': heard,
    })

(OUT/'results.json').write_text(json.dumps(rows, ensure_ascii=False, indent=1))
w = f"{'run':<24}{'chars':>6}{'audio':>9}{'resid':>8}{'guard':>7}{'c/s':>7}{'tail dB':>9}{'verdict':>14}"
print(w); print('-'*len(w))
for r in rows:
    verdict = 'CUT MID-WORD' if r['ends_mid_word'] else 'ends quiet'
    print(f"{r['name']:<24}{r['chars']:>6}{r['audio_true_s'] or 0:9.1f}{r['residual_s']:8.3f}"
          f"{('pass' if r['guard_pass'] else 'REJECT'):>7}{r['apparent_chars_per_s']:7.2f}"
          f"{r['tail_last_100ms_db']:9.1f}{verdict:>14}")
print(f"\ncram profile (does the provider cram unspoken labels at the end?)")
for r in rows:
    c = r['cram']
    if c: print(f"  {r['name']:<24} median={c['median']:.4f}s last-quarter={c['last_quarter_mean']:.4f}s "
                f"ratio={c['ratio']} near-zero-run-at-end={c['zero_run_at_end']}")
print(f"\ncompleteness (needs verify-tails.py)")
for r in rows:
    if r['tail_transcript'] is None: print(f"  {r['name']:<24} (no tail transcript)")
    else: print(f"  {r['name']:<24}\n     submitted last sentence: {r['final_sentence'][:70]}\n"
                f"     heard in last 30 s     : {r['tail_transcript'][-70:]}")
print(f"\nwrote {OUT/'results.json'}")
