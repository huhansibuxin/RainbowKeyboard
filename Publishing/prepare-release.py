#!/usr/bin/env python3
"""Generate offline depictions or a URL-configured, flat APT upload directory."""
import argparse
import bz2
import email.policy
import email.utils
import gzip
import hashlib
import html
import json
import shutil
import subprocess
import tempfile
from email.parser import Parser
from pathlib import Path
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
INFO = HERE / "PackageInfo.json"
if not INFO.exists():
    INFO = HERE.parent / "RainbowKeyboardPrefs/Resources/PackageInfo.json"


def control_fields(text):
    return dict(Parser(policy=email.policy.compat32).parsestr(text).items())


def serialize(fields):
    return "".join(f"{key}: {value}\n" for key, value in fields.items()) + "\n"


def depiction(info, prefix):
    def header(title):
        return {"class": "DepictionHeaderView", "title": title}

    def markdown(text):
        return {"class": "DepictionMarkdownView", "markdown": text.replace("\n", "\n\n"),
                "useSpacing": True}

    content = [header(info["name"]), markdown(info["summary"]), {
        "class": "DepictionScreenshotsView", "itemSize": "{240, 320}", "itemCornerRadius": 8,
        "screenshots": [{"url": prefix + "assets/" + item["file"],
                         "accessibilityText": item["title"]} for item in info["screenshots"]]
    }]
    changes = []
    for section in info["sections"]:
        destination = changes if section["title"] == "更新记录" else content
        destination.extend([header(section["title"]), markdown(section["body"])])
    return {"class": "DepictionTabView", "minVersion": "0.4", "tintColor": "#16806A", "tabs": [
        {"class": "DepictionStackView", "tabname": "详情", "views": content},
        {"class": "DepictionStackView", "tabname": "更新", "views": changes}
    ]}


def site(info, path, prefix=""):
    path.mkdir(parents=True, exist_ok=True)
    shutil.copytree(HERE / "assets", path / "assets")
    (path / "PackageInfo.json").write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n")
    (path / "depiction.json").write_text(json.dumps(depiction(info, prefix), ensure_ascii=False, indent=2) + "\n")
    esc = html.escape
    sections = "".join(
        f'<section><h2>{esc(item["title"])}</h2><p>{esc(item["body"]).replace(chr(10), "<br>")}</p></section>'
        for item in info["sections"])
    shots = "".join(
        f'<a href="assets/{esc(item["file"])}"><img src="assets/{esc(item["file"])}" '
        f'alt="{esc(item["title"])}" width="1080" height="1440"></a>'
        for item in info["screenshots"])
    document = """<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<link rel="icon" href="assets/icon-256.png" type="image/png">
<title>@@NAME@@</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#fafbfc;color:#1a1d22;font:16px/1.8 -apple-system,BlinkMacSystemFont,sans-serif;letter-spacing:0}
main{max-width:880px;margin:auto;padding:28px 20px 64px}header{display:flex;gap:20px;align-items:center;border-bottom:1px solid #dce1e5;padding:0 0 24px}
header img{width:80px;height:80px;border-radius:8px}h1{font-size:26px;line-height:1.4;margin:0 0 6px;overflow-wrap:anywhere}
.meta{font-size:13px;color:#656d76;margin:0}h2{font-size:20px;margin:0 0 10px}p{margin:0 0 18px;overflow-wrap:anywhere}
.summary{margin:24px 0}.screens{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}
.screens img{display:block;width:100%;height:auto;border-radius:8px}.screens a{min-width:0}
section{padding:26px 0;border-bottom:1px solid #dce1e5}a{color:#16806a}footer{padding-top:24px;color:#656d76;font-size:13px}
@media(max-width:420px){header{gap:12px}header img{width:60px;height:60px}h1{font-size:22px}.screens{grid-template-columns:1fr}}
@media(prefers-color-scheme:dark){body{background:#111214;color:#f4f5f6}.meta,footer{color:#a5adb7}header,section{border-color:#30343a}}
</style><main><header><img src="assets/icon-256.png" alt="彩虹键盘图标"><div><h1>@@NAME@@</h1>
<p class="meta">@@VERSION@@ · @@AUTHOR@@</p></div></header><p class="summary">@@SUMMARY@@</p>
<div class="screens">@@SHOTS@@</div>@@SECTIONS@@
<footer>@@IDENTIFIER@@<br>预览来源：插件模拟器实际渲染。</footer></main></html>
"""
    for key, value in {"NAME": esc(info["name"]), "VERSION": esc(info["version"]),
                       "AUTHOR": esc(info["author"]), "SUMMARY": esc(info["summary"]),
                       "SHOTS": shots, "SECTIONS": sections, "IDENTIFIER": esc(info["identifier"])}.items():
        document = document.replace("@@" + key + "@@", value)
    (path / "index.html").write_text(document)


def build(args):
    info = json.loads(INFO.read_text())
    output = args.output.resolve()
    if output.exists():
        raise ValueError("Output already exists; choose a new directory to avoid overwriting a repository.")
    if args.preview_only:
        site(info, output)
        print(f"Offline preview: {output / 'index.html'}")
        return
    base = (args.base_url or "").rstrip("/") + "/"
    url = urlsplit(base)
    if url.scheme != "https" or not url.netloc or url.query or url.fragment or url.username or url.password:
        raise ValueError("Provide the actual HTTPS repository root with --base-url.")
    debs = args.deb or sorted((HERE / "packages").glob("*.deb"))
    if not debs:
        raise ValueError("Supply --deb paths, or put the packages under Publishing/packages/.")
    if not shutil.which("dpkg-deb"):
        raise ValueError("dpkg-deb is required (macOS: brew install dpkg).")
    controls = []
    arches = set()
    for deb in debs:
        fields = control_fields(subprocess.check_output(["dpkg-deb", "-f", str(deb)], text=True))
        if fields.get("Package") != info["identifier"] or fields.get("Version") != info["version"]:
            raise ValueError(f"Package/version mismatch: {deb}")
        arch = fields["Architecture"]
        if arch not in {"iphoneos-arm64", "iphoneos-arm64e"} or arch in arches:
            raise ValueError(f"Unexpected or duplicate architecture: {arch}")
        arches.add(arch)
        controls.append((deb, fields))
    # Build in a sibling temp directory; incomplete uploads never look ready.
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".rainbow-upload-", dir=output.parent) as scratch:
        staging = Path(scratch) / "repo"
        relative = f"depictions/{info['identifier']}/"
        site(info, staging / relative, base + relative)
        (staging / "debs").mkdir()
        entries = []
        for index, (deb, fields) in enumerate(controls):
            unpack = Path(scratch) / f"package-{index}"
            subprocess.run(["dpkg-deb", "-R", str(deb), str(unpack)], check=True)
            fields.update({"Icon": base + relative + "assets/icon-256.png",
                           "Depiction": base + relative + "index.html",
                           "SileoDepiction": base + relative + "depiction.json"})
            (unpack / "DEBIAN/control").write_text(serialize(fields))
            filename = f"{info['identifier']}_{info['version']}_{fields['Architecture']}.deb"
            destination = staging / "debs" / filename
            subprocess.run(["dpkg-deb", "--root-owner-group", "-Zxz", "-b", str(unpack), str(destination)], check=True)
            payload = destination.read_bytes()
            entry = dict(fields)
            entry.update({"Filename": "debs/" + filename, "Size": str(len(payload)),
                          "MD5sum": hashlib.md5(payload).hexdigest(),
                          "SHA256": hashlib.sha256(payload).hexdigest(),
                          "SHA512": hashlib.sha512(payload).hexdigest()})
            entries.append(serialize(entry))
        packages = "".join(entries).encode()
        (staging / "Packages").write_bytes(packages)
        (staging / "Packages.gz").write_bytes(gzip.compress(packages, mtime=0))
        (staging / "Packages.bz2").write_bytes(bz2.compress(packages))
        release = {"Origin": args.name, "Label": args.name, "Suite": "stable", "Codename": "stable",
                   "Architectures": " ".join(sorted(arches)), "Components": "main",
                   "Description": "RainbowKeyboard package repository",
                   "Date": email.utils.formatdate(usegmt=True)}
        text = serialize(release).rstrip() + "\n"
        for field, algorithm in [("MD5Sum", "md5"), ("SHA256", "sha256"), ("SHA512", "sha512")]:
            text += field + ":\n"
            for filename in ["Packages", "Packages.gz", "Packages.bz2"]:
                payload = (staging / filename).read_bytes()
                text += f" {hashlib.new(algorithm, payload).hexdigest()} {len(payload)} {filename}\n"
        (staging / "Release").write_text(text)
        (staging / "Packages.fragment").write_bytes(packages)
        shutil.copy(HERE / "README-publishing.md", staging / "README-publishing.md")
        shutil.copy(HERE / "assets/icon-256.png", staging / "CydiaIcon.png")
        staging.rename(output)
    print(f"Upload directory: {output}")
    print(f"Repository root: {base}")
    print("Existing repository: merge debs/ and depictions/; regenerate its FULL index, do not replace it with this subset.")
    print("Release is unsigned. Use your repository's existing signing workflow if signatures are required.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", help="Actual HTTPS repository root, including any subdirectory")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--deb", action="append", type=Path)
    parser.add_argument("--name", default="RainbowKeyboard")
    parser.add_argument("--preview-only", action="store_true")
    try:
        build(parser.parse_args())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Error: {error}\n")
