# /// script
# requires-python = ">=3.11"
# dependencies = ["faster-whisper"]
# ///
import pathlib, subprocess
from faster_whisper import WhisperModel
OUT = pathlib.Path('/Users/paveltrofimov/Projects/j/reader/scripts/tts-probes/out/2026-09-01-truncation')
m = WhisperModel('large-v3', device='cpu', compute_type='int8')
for mp3 in sorted(OUT.glob('*.mp3')):
    dst = OUT / f'{mp3.stem}.tail.txt'
    if dst.exists(): print(f'{mp3.stem} skip'); continue
    dur = float(subprocess.run(['/opt/homebrew/bin/ffprobe','-v','error','-show_entries','format=duration',
                                '-of','csv=p=0',str(mp3)], capture_output=True, text=True).stdout)
    wav = OUT / f'{mp3.stem}.tail.wav'
    subprocess.run(['/opt/homebrew/bin/ffmpeg','-v','error','-y','-ss',f'{max(0,dur-30)}','-i',str(mp3),
                    '-ac','1','-ar','16000',str(wav)], check=True)
    segs, _ = m.transcribe(str(wav), language='ja', beam_size=5, temperature=0.0,
                           condition_on_previous_text=False)
    dst.write_text(''.join(s.text for s in segs).strip(), encoding='utf-8')
    wav.unlink()
    print(f'{mp3.stem} done')
print('DONE')
