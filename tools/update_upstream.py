"""Add new releases of third-party Reaper extensions to index.xml.

Each package below points ReaPack at the author's own GitHub release file, so nothing is
copied into this repo. Run by .github/workflows/update-upstream.yml; also safe to run by hand.
"""
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

INDEX = Path(__file__).resolve().parent.parent / "index.xml"

PACKAGES = [
    {
        "repo": "bobo198504/SmoothWheelScroll",
        "package": "reaper_smoothwheelscroll-x64.dll",
        "asset": "reaper_smoothwheelscroll-x64.dll",
        "author": "bobo198504",
        "platform": "win64",
    },
]

CATEGORY = "Extensions (third-party)"


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "timzibrat-reapack-updater"})
    with urllib.request.urlopen(req) as r:
        return r.read()


def changelog(body):
    # Release notes are Chinese + English; keep the English part, drop code fences
    text = body or ""
    if "What's changed" in text:
        text = text.split("What's changed", 1)[1]
    text = text.replace("```", "").replace("]]>", "] ]>").strip()
    return text or "New upstream release"


def version_block(pkg, rel):
    asset = next(a for a in rel["assets"] if a["name"] == pkg["asset"])
    digest = hashlib.sha256(get(asset["browser_download_url"])).hexdigest()
    name = rel["tag_name"].lstrip("v")
    return (
        f'      <version name="{name}" author="{pkg["author"]}" time="{rel["published_at"]}">\n'
        f"        <changelog><![CDATA[{changelog(rel['body'])}]]></changelog>\n"
        f'        <source platform="{pkg["platform"]}" hash="1220{digest}">'
        f'{asset["browser_download_url"]}</source>\n'
        f"      </version>\n"
    ), name


def main():
    xml = INDEX.read_text(encoding="utf-8")
    added = []
    for pkg in PACKAGES:
        rel = json.loads(get(f"https://api.github.com/repos/{pkg['repo']}/releases/latest"))
        block, name = version_block(pkg, rel)
        open_tag = f'<reapack name="{pkg["package"]}" type="extension">'
        if open_tag not in xml:
            if f'<category name="{CATEGORY}">' not in xml:
                xml = xml.replace("</index>", f'  <category name="{CATEGORY}">\n  </category>\n</index>')
            xml = xml.replace(
                f'<category name="{CATEGORY}">\n',
                f'<category name="{CATEGORY}">\n    {open_tag}\n    </reapack>\n', 1)
        start = xml.index(open_tag)
        end = xml.index("</reapack>", start)
        if re.search(rf'<version name="{re.escape(name)}"', xml[start:end]):
            continue
        line_start = xml.rindex("\n", 0, end) + 1  # keep "    </reapack>" on its own line
        xml = xml[:line_start] + block + xml[line_start:]
        added.append(f"{pkg['package']} {name}")
    if added:
        INDEX.write_text(xml, encoding="utf-8")
    print("added: " + ", ".join(added) if added else "up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
