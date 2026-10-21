#!/usr/bin/env python3
"""Writes the Sparkle appcast for one release.

    scripts/make_appcast.py --version 0.2.0 --build 42 --dmg build/release/Cluvia-0.2.0.dmg \
        --ed-signature <base64> --url https://…/Cluvia-0.2.0.dmg --changelog CHANGELOG.md > appcast.xml

The app reads the appcast of the latest GitHub release, so it only needs the newest item. Release notes are that
version's CHANGELOG.md section, rendered as simple HTML.
"""
import argparse
import html
import os
import re
import sys
from email.utils import formatdate

MIN_SYSTEM_VERSION = "14.0"


def inline(markdown: str) -> str:
    """Escapes text, then renders **bold** and [links](url)."""
    text = html.escape(markdown, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    return re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', text)


def release_notes(changelog: str, version: str) -> str:
    """HTML for the `## [version]` (or `## version`) section, without trailing commit links."""
    lines, inside, html_parts, open_list = changelog.splitlines(), False, [], False
    heading = re.compile(r"^## \[?(\d+\.\d+\.\d+[^\]\s]*)\]?")
    for line in lines:
        match = heading.match(line)
        if match:
            if inside:
                break
            inside = match.group(1) == version
            continue
        if not inside:
            continue
        if line.startswith("### "):
            if open_list:
                html_parts.append("</ul>")
                open_list = False
            html_parts.append(f"<h3>{inline(line[4:].strip())}</h3>")
        elif line.startswith(("* ", "- ")):
            if not open_list:
                html_parts.append("<ul>")
                open_list = True
            item = re.sub(r"\s*\(\[[0-9a-f]{7,40}\]\([^)]*\)\)\s*$", "", line[2:].strip())
            html_parts.append(f"<li>{inline(item)}</li>")
    if open_list:
        html_parts.append("</ul>")
    return "\n".join(html_parts) or "<p>See the release notes on GitHub.</p>"


def appcast(version: str, build: str, url: str, length: int, signature: str, notes: str) -> str:
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cluvia</title>
    <link>https://github.com/Eliitme/Cluvia</link>
    <item>
      <title>Cluvia {html.escape(version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{html.escape(url)}" length="{length}" type="application/octet-stream" sparkle:edSignature="{html.escape(signature)}"/>
    </item>
  </channel>
</rss>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString, e.g. 0.2.0")
    parser.add_argument("--build", required=True, help="CFBundleVersion of the built app")
    parser.add_argument("--dmg", required=True, help="path to the signed, notarized DMG")
    parser.add_argument("--ed-signature", required=True, help="EdDSA signature from Sparkle's sign_update")
    parser.add_argument("--url", required=True, help="download URL of the DMG")
    parser.add_argument("--changelog", default="CHANGELOG.md")
    args = parser.parse_args()
    with open(args.changelog, encoding="utf-8") as file:
        notes = release_notes(file.read(), args.version)
    sys.stdout.write(appcast(args.version, args.build, args.url, os.path.getsize(args.dmg), args.ed_signature, notes))


if __name__ == "__main__":
    main()
