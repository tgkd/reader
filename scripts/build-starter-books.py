#!/usr/bin/env python3
import csv
import io
import re
import sys
import urllib.request
import zipfile
from pathlib import Path

INDEX_URL = "https://www.aozora.gr.jp/index_pages/list_person_all_extended_utf8.zip"
X0213_URL = "http://x0213.org/codetable/jisx0213-2004-std.txt"

REPO = Path(__file__).resolve().parent.parent
OUT_DIR = REPO / "app" / "Reader" / "Resources" / "StarterBooks"
CACHE_DIR = REPO / "build" / "aozora-cache"

BOOKS = [
    ("yamanashi", "046605"),
    ("kumo-no-ito", "000092"),
    ("rashomon", "000127"),
    ("chumon-no-oi-ryoriten", "043754"),
    ("lemon", "000424"),
    ("gon-gitsune", "000628"),
    ("sangetsuki", "000624"),
    ("yume-juya", "000799"),
]

COL_TITLE = 1
COL_COPYRIGHT = 10
COL_UPDATED = 12
COL_SURNAME = 15
COL_GIVEN = 16
COL_ROLE = 23
COL_PERSON_COPYRIGHT = 26
COL_SOURCE = 27
COL_PUBLISHER = 28
COL_TYPIST = 43
COL_PROOFER = 44
COL_XHTML = 50

GAIJI_TAG = re.compile(r'<img\b[^>]*class="gaiji"[^>]*>')
ALT_ATTR = re.compile(r'alt="([^"]*)"')
KUTEN = re.compile(r"第[34]水準(\d)-(\d+)-(\d+)")
HEADING_MARK = "\x01"


def fetch(url, cache):
    if cache.exists():
        return cache.read_bytes()
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_bytes(data)
    return data


def gaiji_table():
    raw = fetch(X0213_URL, CACHE_DIR / "jisx0213-2004-std.txt").decode("utf-8")
    table = {}
    for line in raw.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        cols = line.split("\t")
        if len(cols) < 2 or not cols[1].startswith("U+"):
            continue
        table[cols[0]] = "".join(chr(int(c, 16)) for c in cols[1][2:].split("+"))
    return table


def kuten_char(table, plane, ku, ten):
    return table.get(f"{3 if plane == 1 else 4}-{ku + 32:02X}{ten + 32:02X}")


def aozora_index():
    archive = fetch(INDEX_URL, CACHE_DIR / "aozora-index.zip")
    with zipfile.ZipFile(io.BytesIO(archive)) as zf:
        name = next(n for n in zf.namelist() if n.endswith(".csv"))
        text = zf.read(name).decode("utf-8-sig")
    index = {}
    for row in csv.reader(io.StringIO(text)):
        if len(row) <= COL_XHTML or row[COL_ROLE] != "著者":
            continue
        index.setdefault(row[0], row)
    return index


def resolve_gaiji(html, table, slug):
    def replace(match):
        alt = ALT_ATTR.search(match.group(0))
        code = KUTEN.search(alt.group(1)) if alt else None
        if not code:
            sys.exit(f"{slug}: gaiji without a kuten code: {match.group(0)}")
        char = kuten_char(table, int(code.group(1)), int(code.group(2)), int(code.group(3)))
        if not char:
            sys.exit(f"{slug}: unmapped gaiji {code.group(0)} in {alt.group(1)}")
        return char

    return GAIJI_TAG.sub(replace, html)


def extract_main_text(html, slug):
    opener = re.search(r'<div\b[^>]*class="main_text"[^>]*>', html)
    if not opener:
        sys.exit(f"{slug}: no main_text block")
    start = opener.end()
    depth = 1
    for match in re.finditer(r"<(/?)div\b[^>]*>", html[start:]):
        depth += -1 if match.group(1) else 1
        if depth == 0:
            return html[start:start + match.start()]
    sys.exit(f"{slug}: unbalanced main_text block")


def strip_tags(fragment):
    return re.sub(r"(?is)<[^>]+>", "", fragment).strip(" \t\r\n")


def to_blocks(main, table, slug):
    s = resolve_gaiji(main, table, slug)
    s = re.sub(r"(?is)<a\b[^>]*>|</a\s*>", "", s)
    s = re.sub(r"(?is)<h[1-6]\b[^>]*>", "\n" + HEADING_MARK, s)
    s = re.sub(r"(?is)</h[1-6]\s*>", "\n", s)
    s = re.sub(r"(?is)<br\s*/?>", "\n", s)
    s = re.sub(r"(?is)<div\b[^>]*>|</div\s*>", "\n", s)
    blocks = []
    for line in s.split("\n"):
        line = line.strip(" \t\r\n")
        if not line:
            continue
        if line.startswith(HEADING_MARK):
            heading = strip_tags(line[1:])
            if heading:
                blocks.append(("heading", heading))
        else:
            blocks.append(("para", line))
    return blocks


def to_chapters(blocks):
    chapters = []
    current = None
    for kind, content in blocks:
        if kind == "heading":
            current = {"title": content, "paras": []}
            chapters.append(current)
            continue
        if current is None:
            current = {"title": None, "paras": []}
            chapters.append(current)
        current["paras"].append(content)
    return [c for c in chapters if c["paras"]]


def xml_escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def chapter_xhtml(chapter, index):
    heading = ""
    if chapter["title"]:
        heading = f"  <h1>{xml_escape(chapter['title'])}</h1>\n"
    body = "\n".join(f"  <p>{p}</p>" for p in chapter["paras"])
    title = xml_escape(chapter["title"] or f"{index}")
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja">\n'
        f"<head><title>{title}</title>"
        '<meta charset="utf-8"/>'
        '<link rel="stylesheet" type="text/css" href="../style.css"/></head>\n'
        "<body>\n"
        f"{heading}{body}\n"
        "</body>\n</html>\n"
    )


STYLE = """body { font-family: serif; line-height: 1.8; margin: 1em; }
h1 { font-weight: normal; font-size: 1.1em; margin: 2em 0; }
p { margin: 0; text-indent: 0; }
"""

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""


def build_opf(meta, chapters):
    items = []
    spine = []
    for i in range(len(chapters)):
        ident = f"chap{i + 1:03d}"
        items.append(
            f'    <item id="{ident}" href="text/{ident}.xhtml" media-type="application/xhtml+xml"/>'
        )
        spine.append(f'    <itemref idref="{ident}"/>')
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="bookid" xml:lang="ja">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        f'    <dc:identifier id="bookid">urn:aozora:{meta["work_id"]}</dc:identifier>\n'
        f'    <dc:title>{xml_escape(meta["title"])}</dc:title>\n'
        f'    <dc:creator>{xml_escape(meta["author"])}</dc:creator>\n'
        "    <dc:language>ja</dc:language>\n"
        f'    <dc:source>{xml_escape(meta["source"])}</dc:source>\n'
        f'    <dc:rights>{xml_escape(meta["rights"])}</dc:rights>\n'
        f'    <dc:contributor>{xml_escape(meta["contributor"])}</dc:contributor>\n'
        f'    <meta property="dcterms:modified">{meta["modified"]}</meta>\n'
        "  </metadata>\n"
        "  <manifest>\n"
        '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\n'
        '    <item id="style" href="style.css" media-type="text/css"/>\n'
        + "\n".join(items)
        + "\n  </manifest>\n"
        "  <spine>\n"
        + "\n".join(spine)
        + "\n  </spine>\n</package>\n"
    )


def build_nav(meta, chapters):
    entries = []
    for i, chapter in enumerate(chapters):
        label = chapter["title"] or meta["title"]
        entries.append(
            f'      <li><a href="text/chap{i + 1:03d}.xhtml">{xml_escape(label)}</a></li>'
        )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja" lang="ja">\n'
        f'<head><title>{xml_escape(meta["title"])}</title><meta charset="utf-8"/></head>\n'
        "<body>\n"
        '  <nav epub:type="toc" id="toc">\n'
        "    <ol>\n" + "\n".join(entries) + "\n    </ol>\n"
        "  </nav>\n</body>\n</html>\n"
    )


def write_epub(path, meta, chapters):
    stamp = (2026, 1, 1, 0, 0, 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as zf:
        mimetype = zipfile.ZipInfo("mimetype", stamp)
        mimetype.compress_type = zipfile.ZIP_STORED
        zf.writestr(mimetype, "application/epub+zip")

        def add(name, text):
            info = zipfile.ZipInfo(name, stamp)
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, text.encode("utf-8"))

        add("META-INF/container.xml", CONTAINER)
        add("OEBPS/content.opf", build_opf(meta, chapters))
        add("OEBPS/nav.xhtml", build_nav(meta, chapters))
        add("OEBPS/style.css", STYLE)
        for i, chapter in enumerate(chapters):
            add(f"OEBPS/text/chap{i + 1:03d}.xhtml", chapter_xhtml(chapter, i + 1))


def main():
    table = gaiji_table()
    index = aozora_index()
    total_bytes = 0
    print(f"{'book':26s} {'chars':>7s} {'chapters':>9s} {'bytes':>7s}  title")
    for slug, work_id in BOOKS:
        row = index.get(work_id)
        if row is None:
            sys.exit(f"{slug}: work id {work_id} not in the Aozora index")
        if row[COL_COPYRIGHT] != "なし" or row[COL_PERSON_COPYRIGHT] != "なし":
            sys.exit(f"{slug}: work {work_id} is not public domain")
        url = row[COL_XHTML]
        if not url:
            sys.exit(f"{slug}: work {work_id} has no XHTML edition")

        raw = fetch(url, CACHE_DIR / f"{work_id}.html")
        html = raw.decode("shift_jis")
        main_text = extract_main_text(html, slug)
        chapters = to_chapters(to_blocks(main_text, table, slug))
        if not chapters:
            sys.exit(f"{slug}: no chapters produced")

        author = f"{row[COL_SURNAME]}{row[COL_GIVEN]}"
        source = f"{row[COL_SOURCE]}（{row[COL_PUBLISHER]}）"
        meta = {
            "work_id": work_id,
            "title": row[COL_TITLE],
            "author": author,
            "source": source,
            "rights": "青空文庫 (https://www.aozora.gr.jp/) — 著作権消滅作品",
            "contributor": f"入力: {row[COL_TYPIST]} / 校正: {row[COL_PROOFER]}",
            "modified": f"{row[COL_UPDATED].replace('/', '-')}T00:00:00Z",
        }
        path = OUT_DIR / f"{slug}.epub"
        write_epub(path, meta, chapters)

        chars = sum(len(strip_tags(p)) for c in chapters for p in c["paras"])
        size = path.stat().st_size
        total_bytes += size
        print(f"{slug:26s} {chars:7d} {len(chapters):9d} {size:7d}  {meta['title']}（{author}）")
    print(f"\n{len(BOOKS)} books, {total_bytes} bytes total → {OUT_DIR.relative_to(REPO)}")


if __name__ == "__main__":
    main()
