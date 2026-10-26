#!/usr/bin/env python3
"""Adds a release to the Sparkle appcast (newest first), creating the file if needed."""
import argparse
import html
import os
from email.utils import formatdate

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

EMPTY_FEED = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">
    <channel>
        <title>MELEMT</title>
        <link>https://github.com/kfalencik/MELEMT</link>
        <description>MELEMT updates</description>
        <language>en</language>
    </channel>
</rss>
"""


def notes_html(path):
    """Very small Markdown-to-HTML: headings, bullet lists and paragraphs."""
    out, in_list = [], False
    for raw in open(path, encoding="utf-8").read().splitlines():
        line = raw.strip()
        if line.startswith(("- ", "* ")):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{html.escape(line[2:])}</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if line.startswith("#"):
            out.append(f"<h3>{html.escape(line.lstrip('#').strip())}</h3>")
        elif line:
            out.append(f"<p>{html.escape(line)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("appcast")
    parser.add_argument("--version", required=True, help="CFBundleVersion")
    parser.add_argument("--short-version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--min-system", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature-attrs", required=True, help='sign_update output: sparkle:edSignature="…" length="…"')
    parser.add_argument("--release-page", required=True)
    parser.add_argument("--notes")
    args = parser.parse_args()

    feed = open(args.appcast, encoding="utf-8").read() if os.path.exists(args.appcast) else EMPTY_FEED
    if f"<sparkle:version>{args.version}</sparkle:version>" in feed:
        raise SystemExit(f"appcast already has build {args.version}")

    description = notes_html(args.notes) if args.notes else f'<p><a href="{args.release_page}">Release notes</a></p>'
    item = f"""        <item>
            <title>Version {args.short_version}</title>
            <pubDate>{formatdate(usegmt=True)}</pubDate>
            <sparkle:version>{args.version}</sparkle:version>
            <sparkle:shortVersionString>{args.short_version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{args.min_system}</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>{args.release_page}</sparkle:fullReleaseNotesLink>
            <description><![CDATA[
{description}
            ]]></description>
            <enclosure url="{args.url}" type="application/octet-stream" {args.signature_attrs.strip()} />
        </item>
"""
    # Newest release goes right after the channel header.
    marker = "<language>en</language>\n"
    if marker not in feed:
        raise SystemExit("unexpected appcast format")
    feed = feed.replace(marker, marker + item, 1)
    with open(args.appcast, "w", encoding="utf-8") as f:
        f.write(feed)


if __name__ == "__main__":
    main()
