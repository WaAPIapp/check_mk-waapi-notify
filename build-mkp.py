#!/usr/bin/env python3
"""Build a Checkmk MKP package without a Checkmk site.

An MKP is a gzipped tar containing:

    info        the manifest as a Python dict literal (pprint format)
    info.json   the same manifest as JSON, for external tools
    <part>.tar  one tar per package part, paths relative to that part's
                local directory

The part identifiers and their file permissions are defined in Checkmk's own
packager (packages/cmk-mkp-tool/cmk/mkp_tool/_mkp.py and _parts.py). A
notification script belongs to the "notifications" part, which maps to
~/local/share/check_mk/notifications/ and is installed with mode 0700.

Usage:
    python3 build-mkp.py [--version X.Y.Z] [--output DIR]
"""

from __future__ import annotations

import argparse
import io
import json
import pprint
import tarfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent

NAME = "whatsapp_notify"
TITLE = "WhatsApp notifications (via WaAPI)"
AUTHOR = "WaAPI <info@waapi.app>"
DOWNLOAD_URL = "https://github.com/WaAPIapp/check_mk-whatsapp-notify"
VERSION_MIN_REQUIRED = "2.0.0b1"
PACKAGED_BY = "waapi build-mkp.py 1.0"

DESCRIPTION = """\
Send Checkmk host and service notifications as WhatsApp messages through the
WaAPI REST API (https://waapi.app).

The plugin is a single bash script with no dependencies beyond curl. Configure
it under Setup > Events > Notifications with the notification method
"Push Notification (using WhatsApp with waapi.app)" and these parameters:

  1  WaAPI instance ID          e.g. 123
  2  Destination chat ID        e.g. 4915112345678@c.us or <group-id>@g.us
  3  WaAPI API token
  4  API base URL               optional

Verify the configuration from the site shell before creating the rule:

  ~/local/share/check_mk/notifications/check_mk_whatsapp-notify.sh \\
      --test <instance> <chatId> <token>

Requires a waapi.app account with an instance connected to a phone number.

WhatsApp is a trademark of WhatsApp LLC. This package is an independent
integration and is not affiliated with, endorsed or sponsored by WhatsApp LLC,
Meta or Checkmk GmbH.
"""

# part identifier -> (source file in this repo, path inside the part)
# Permissions follow Checkmk's own mapping: notifications are executable (0700),
# everything else is 0600.
PARTS: dict[str, list[tuple[Path, str]]] = {
    "notifications": [(REPO / "check_mk_whatsapp-notify.sh", "check_mk_whatsapp-notify.sh")],
    "doc": [(REPO / "README.md", "whatsapp_notify.md")],
}
EXECUTABLE_PARTS = {"notifications", "agents", "bin", "alert_handlers"}


def _tar_info(name: str, size: int, mode: int = 0o644) -> tarfile.TarInfo:
    info = tarfile.TarInfo()
    info.name = name
    info.size = size
    info.mode = mode
    info.mtime = int(time.time())
    info.uid = 0
    info.gid = 0
    info.type = tarfile.REGTYPE
    return info


def _build_part_tar(part: str, entries: list[tuple[Path, str]]) -> bytes:
    mode = 0o700 if part in EXECUTABLE_PARTS else 0o600
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for source, rel_path in entries:
            payload = source.read_bytes()
            item = _tar_info(rel_path, len(payload), mode)
            item.uname = "cmk"
            item.gname = "cmk"
            tar.addfile(item, io.BytesIO(payload))
    return buf.getvalue()


def build(version: str, output_dir: Path) -> Path:
    for entries in PARTS.values():
        for source, _ in entries:
            if not source.is_file():
                raise SystemExit(f"missing source file: {source}")

    manifest = {
        "author": AUTHOR,
        "description": DESCRIPTION,
        "download_url": DOWNLOAD_URL,
        "files": {part: [rel for _, rel in entries] for part, entries in PARTS.items()},
        "name": NAME,
        "title": TITLE,
        "version": version,
        "version.min_required": VERSION_MIN_REQUIRED,
        "version.packaged": PACKAGED_BY,
        "version.usable_until": None,
    }

    members: list[tuple[str, bytes]] = [
        ("info", (pprint.pformat(manifest) + "\n").encode()),
        ("info.json", json.dumps(manifest).encode()),
    ]
    for part, entries in PARTS.items():
        members.append((f"{part}.tar", _build_part_tar(part, entries)))

    output_dir.mkdir(parents=True, exist_ok=True)
    target = output_dir / f"{NAME}-{version}.mkp"

    with tarfile.open(target, mode="w:gz") as tar:
        for name, payload in members:
            tar.addfile(_tar_info(name, len(payload)), io.BytesIO(payload))

    return target


def verify(mkp: Path) -> None:
    """Re-read the finished package and assert it is installable.

    Cheap insurance: a malformed MKP is only rejected once someone tries to
    install it on a real site, which is exactly the feedback loop this script
    exists to avoid.
    """
    import ast
    import tarfile as _tarfile

    with _tarfile.open(mkp, "r:gz") as tar:
        names = tar.getnames()
        for required in ("info", "info.json", *(f"{part}.tar" for part in PARTS)):
            if required not in names:
                raise SystemExit(f"package is missing {required}")

        info_py = ast.literal_eval(tar.extractfile("info").read().decode())
        info_js = json.loads(tar.extractfile("info.json").read().decode())
        if info_py != info_js:
            raise SystemExit("info and info.json disagree")

        for part, entries in PARTS.items():
            expected_mode = 0o700 if part in EXECUTABLE_PARTS else 0o600
            payload = io.BytesIO(tar.extractfile(f"{part}.tar").read())
            with _tarfile.open(fileobj=payload) as inner:
                for source, rel_path in entries:
                    member = inner.getmember(rel_path)
                    if member.mode != expected_mode:
                        raise SystemExit(
                            f"{part}/{rel_path}: expected mode "
                            f"{expected_mode:o}, got {member.mode:o}"
                        )
                    if inner.extractfile(member).read() != source.read_bytes():
                        raise SystemExit(f"{part}/{rel_path} does not match {source}")

    print(f"verified {mkp.name}: manifest consistent, {sum(len(e) for e in PARTS.values())} files, permissions correct")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="2.0.0", help="package version (default: 2.0.0)")
    parser.add_argument("--output", type=Path, default=REPO / "dist", help="output directory")
    args = parser.parse_args()

    target = build(args.version, args.output)
    print(f"built {target} ({target.stat().st_size} bytes)")
    verify(target)


if __name__ == "__main__":
    main()
