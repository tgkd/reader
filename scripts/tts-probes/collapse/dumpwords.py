import sys,json
from faster_whisper import WhisperModel
wav,out=sys.argv[1],sys.argv[2]
model=WhisperModel("large-v3",device="cpu",compute_type="int8")
segs,_=model.transcribe(wav,language="ja",beam_size=5,temperature=0.0,word_timestamps=True,condition_on_previous_text=False)
json.dump([[w.word,w.start,w.end] for s in segs for w in s.words],open(out,"w"),ensure_ascii=False)
