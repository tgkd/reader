# App Store screenshots — Claude design handoff

Everything to upload lives in **`appstore-screenshots/upload/`** (gitignored):
`PROMPT.md` (the design brief — slide plan, brand palette, copy, export specs)
plus the raw device captures (`raw-*.png`, iPhone 17 Pro simulator) and
`icon-1024.png`. Upload the whole folder to a Claude design session; the prompt
references the attachments by filename.

Slide copy and ordering mirror `docs/app-store.md` §3 — change them there first,
then in `PROMPT.md`.

## Retaking the raw captures

Boot the dev sim (iPhone 17 Pro `FE453587…`, `DEVELOPER_DIR` per the Xcode-27
beta note), `scripts/uitest/install.sh`, then drive with `scripts/uitest/lib.sh`
helpers (`tap_label`, `shot`). Launch with `-AppleLanguages "(en)"` for English
chrome; set `simctl status_bar … override --time "9:41" --batteryLevel 100` first.
Sample books: `samples/こころ（夏目漱石）.epub`, `samples/銀河鉄道の夜（宮沢賢治）.pdf`
(seed via the sim's File Provider Storage, import through the `+` picker).

`raw-03-playing.png` (word-synced highlight + player pill) and
`raw-10-lockscreen.png` need an active StoreKit-test Membership: run once from
Xcode (Cmd-R activates `Reader.storekit`), subscribe via the paywall, then play
a chapter (this bills one live synthesis) and use `idb ui button LOCK` for the
lock-screen frame.
