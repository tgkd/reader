#!/usr/bin/env python3
import sys
import zipfile

VS17 = "\U000E0100"
VS18 = "\U000E0101"
DAKUTEN = "゙"

BODY = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">
<head><title>異体字セレクタ</title></head>
<body>
<h1>異体字セレクタの章</h1>

<p>一、選択子つき・ルビなし</p>
<p>　葛{VS17}城さんは辻{VS18}さんと嵜{VS17}山さんに会った。</p>

<p>二、選択子つき・出版社ルビあり</p>
<p>　<ruby>葛{VS17}城<rt>かつらぎ</rt></ruby>さんは<ruby>辻{VS18}<rt>つじ</rt></ruby>さんと歩いた。</p>

<p>三、対照群・選択子なし</p>
<p>　葛城さんは辻さんと嵜山さんに会った。</p>

<p>四、結合文字</p>
<p>　が{DAKUTEN}っこうへ行くと先生がいた。</p>

<p>五、通常の文</p>
<p>　吾輩は猫である。名前はまだ無い。今日は良い天気ですね。</p>
</body>
</html>
"""

OPF = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:ivs-test-0001</dc:identifier>
    <dc:title>異体字テスト</dc:title>
    <dc:creator>トークナイザ検証</dc:creator>
    <dc:language>ja</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
  </spine>
</package>
"""

NAV = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja">
<head><title>目次</title></head>
<body>
<nav epub:type="toc"><ol><li><a href="ch1.xhtml">異体字セレクタの章</a></li></ol></nav>
</body>
</html>
"""

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
"""


def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/yomi-uitest/ivs-test.epub"
    with zipfile.ZipFile(out, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip",
                   compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", CONTAINER)
        z.writestr("OEBPS/content.opf", OPF)
        z.writestr("OEBPS/nav.xhtml", NAV)
        z.writestr("OEBPS/ch1.xhtml", BODY)
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
