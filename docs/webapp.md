Good question — and the honest answer is **yes, it can be a strong web app.** None of the four pieces is a blocker; two are actually *easier* on the web than on iOS. Let me go piece by piece.

**Tokenizer — solvable, this is the only real consideration.** You can't run MeCab+IPADic natively in a browser, but there are real options:
- **kuromoji.js** — pure-JS Japanese tokenizer with IPADic, gives surface + reading + dictionary_form (exactly the three things we need). ~5–15 MB dictionary, loaded once and cached. This is the pragmatic default and is what most JP-learning web apps use.
- **MeCab compiled to WASM** (e.g. mecab-wasm / lindera-wasm) — keeps you bit-for-bit consistent with the iOS tokenizer, which matters because our whole thesis is "one tokenizer is the single source of truth." Heavier setup but eliminates any segmentation drift between platforms.
- **Server-side tokenize** — run the same MeCab in a Worker/edge function and return tokens. Since we already pre-generate audio server-side (the research's verdict), tokenizing in the same batch is natural and keeps the dictionary off the client entirely.

The catch isn't capability, it's **consistency**: if web uses kuromoji and iOS uses MeCab-Swift, their segmentation can disagree on edge cases, and the char→token mapper + furigana would diverge between platforms. The clean fix is to tokenize **once on the server** and ship tokens to both clients — which also shrinks the web bundle.

**Parsing (char→token sync) — trivially portable.** `CharTokenMapper` is pure logic (two-pointer + clamp, no platform APIs). It's ~130 lines of straightforward code that ports to TypeScript almost line-for-line. Zero web risk.

**Rendering — *easier* on the web.** This is the part that's *hard* on iOS and *native* on the web:
- Furigana = the HTML `<ruby><rt>` element. The design mockup already uses it.
- Vertical tategaki = `writing-mode: vertical-rl`. One CSS line. (On iOS this forced us into a custom CoreText view — the web gets it for free.)
- The synced highlight = a `<span>` per token with a background transition, exactly as the Yomi mockup demonstrates — and the mockup *is* a working web rendering of it.
In other words, the design we just imported is literally proof the web rendering works.

**Cache — fine, with a footnote.** Audio (MP3 blobs) + alignment JSON cache cleanly via **Cache Storage / IndexedDB**, and a service worker gives real offline reading. The footnote: browser storage is evictable and quota-limited (origin caps, iOS Safari is stingier), so "download for offline" is best-effort rather than guaranteed permanent the way an iOS app's Documents dir is.

**The one genuinely platform-specific weak spot is audio background playback**, not any of the four you listed. A native iOS app keeps narrating with the screen locked (the `UIBackgroundModes: [audio]` we just wired); a web app's audio generally suspends when the tab backgrounds or the phone locks. For a read-along reader that's a real UX downgrade.

**Bottom line:** rendering and parsing are web-friendly (rendering more so than iOS), cache is good-enough, and the tokenizer is solvable — best via server-side tokenization so both platforms share one segmentation. If you want this to be cross-platform, the cleanest architecture is **tokenize + synthesize + align on the server, ship tokens+audio+alignment to thin clients**, and the iOS-native advantage narrows mostly to background audio and guaranteed offline storage. Worth noting our current `ReaderCore` is Swift, so a web app wouldn't reuse that code directly — but the *design* (single-tokenizer thesis, content-addressed cache, char→token mapper) ports cleanly.