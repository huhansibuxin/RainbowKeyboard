#!/usr/bin/env python3
"""Check generated APT hashes, online metadata, depictions and packaged resources."""
import bz2
import gzip
import hashlib
import io
import json
import plistlib
import subprocess
import sys
import tarfile
from pathlib import Path
from urllib.parse import urlsplit
from importlib.util import spec_from_file_location, module_from_spec

spec = spec_from_file_location("release", Path(__file__).with_name("prepare-release.py"))
release = module_from_spec(spec)
spec.loader.exec_module(release)
root = Path(sys.argv[1]).resolve()
base = sys.argv[2].rstrip("/") + "/"
raw = (root / "Packages").read_bytes()
assert gzip.decompress((root / "Packages.gz").read_bytes()) == raw
assert bz2.decompress((root / "Packages.bz2").read_bytes()) == raw
entries = [release.control_fields(part) for part in raw.decode().strip().split("\n\n")]
assert 1 <= len(entries) <= 2
for entry in entries:
    path = root / entry["Filename"]
    payload = path.read_bytes()
    assert len(payload) == int(entry["Size"])
    for field, algorithm in [("MD5sum", "md5"), ("SHA256", "sha256"), ("SHA512", "sha512")]:
        assert hashlib.new(algorithm, payload).hexdigest() == entry[field]
    control = release.control_fields(subprocess.check_output(["dpkg-deb", "-f", str(path)], text=True))
    for key in ["Icon", "Depiction", "SileoDepiction"]:
        assert control[key] == entry[key]
        assert entry[key].startswith(base)
        assert (root / entry[key][len(base):]).is_file()
    native = json.loads((root / entry["SileoDepiction"][len(base):]).read_text())
    assert native["class"] == "DepictionTabView" and len(native["tabs"]) == 2
    shots = native["tabs"][0]["views"][2]["screenshots"]
    assert len(shots) == 2
    for item in shots:
        assert urlsplit(item["url"]).scheme == "https" and item["url"].startswith(base)
        assert (root / item["url"][len(base):]).is_file()
        assert item["accessibilityText"]
    archive = subprocess.check_output(["dpkg-deb", "--fsys-tarfile", str(path)])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        files = tar.getnames()
        for name in ["icon.png", "icon@2x.png", "icon@3x.png", "PackageIcon.png",
                     "PackageInfo.json", "SliderHelp.plist", "preview-neon.png", "preview-colors.png"]:
            assert any(f"/RainbowKeyboardPrefs.bundle/{name}" in item for item in files), name
        assert sum(item.endswith("/Preferences/com.minis.rainbowkeyboard.prefs.plist") for item in files) == 1
        info_paths = [item for item in files if item.endswith("/RainbowKeyboardPrefs.bundle/Info.plist")]
        assert len(info_paths) == 1
        info = plistlib.loads(tar.extractfile(info_paths[0]).read())
        assert info.get("NSPrincipalClass") == "RKBRootListController", "Incorrect settings entry class"
release_fields = release.control_fields((root / "Release").read_text())
for field, algorithm in [("MD5Sum", "md5"), ("SHA256", "sha256"), ("SHA512", "sha512")]:
    for line in release_fields[field].strip().splitlines():
        digest, length, name = line.split()
        data = (root / name).read_bytes()
        assert len(data) == int(length)
        assert hashlib.new(algorithm, data).hexdigest() == digest
print(f"PASS: {len(entries)} packages; control URLs, assets, resource bundle and all repository hashes.")
