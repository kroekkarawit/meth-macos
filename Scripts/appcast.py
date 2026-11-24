#!/usr/bin/env python3
"""Adds (or replaces) one release in a Sparkle 2 appcast.

usage: appcast.py APPCAST VERSION BUILD ARCHIVE_URL LENGTH ED_SIGNATURE MIN_MACOS CHANGELOG

Older items are kept, so every published version stays upgradeable. Items are
ordered by build number (sparkle:version), newest first; Sparkle compares
sparkle:version, which is CFBundleVersion and increases monotonically.
"""
import datetime, html, re, sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", DC)

def changelog_html(path, version):
    text = open(path, encoding="utf-8").read()
    m = re.search(rf"^## \[?{re.escape(version)}\]?.*?$(.*?)(?=^## |\Z)", text, re.S | re.M)
    if not m:
        sys.exit(f"CHANGELOG.md has no section for {version}")
    out, in_list = [], False
    for line in m.group(1).strip().splitlines():
        line = line.rstrip()
        if line.startswith(("- ", "* ")):
            if not in_list:
                out.append("<ul>"); in_list = True
            out.append(f"<li>{html.escape(line[2:])}</li>")
            continue
        if in_list:
            out.append("</ul>"); in_list = False
        if line.startswith("### "):
            out.append(f"<h3>{html.escape(line[4:])}</h3>")
        elif line:
            out.append(f"<p>{html.escape(line)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)

def main():
    appcast, version, build, url, length, sig, min_os, changelog = sys.argv[1:9]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        sys.exit(f"Not a semantic version: {version}")
    try:
        tree = ET.parse(appcast)
        channel = tree.getroot().find("channel")
    except (FileNotFoundError, ET.ParseError):
        rss = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "Meth"
        ET.SubElement(channel, "link").text = "https://github.com/kroekkarawit/meth-macos"
        ET.SubElement(channel, "description").text = "Meth updates"
        ET.SubElement(channel, "language").text = "en"
        tree = ET.ElementTree(rss)

    for item in list(channel.findall("item")):
        if item.findtext(f"{{{SPARKLE}}}shortVersionString") == version:
            channel.remove(item)
        elif int(item.findtext(f"{{{SPARKLE}}}version") or 0) >= int(build):
            sys.exit(f"Build {build} is not newer than published build {item.findtext(f'{{{SPARKLE}}}version')}")

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {version}"
    ET.SubElement(item, "pubDate").text = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = min_os
    ET.SubElement(item, "description").text = changelog_html(changelog, version)
    ET.SubElement(item, "enclosure", {
        "url": url, "length": length, "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": sig,
    })

    items = channel.findall("item") + [item]
    for i in channel.findall("item"):
        channel.remove(i)
    for i in sorted(items, key=lambda i: int(i.findtext(f"{{{SPARKLE}}}version")), reverse=True):
        channel.append(i)
    ET.indent(tree, space="  ")
    tree.write(appcast, encoding="utf-8", xml_declaration=True)
    print(f"appcast: {version} ({build}) -> {url}")

main()
