#!/usr/bin/env python3
"""Build governance/BOOT_INDEX.json from governance/CURRENT.json.

The index is a small derived summary the AI reads at the start of a chat.
It records the git blob SHA of CURRENT.json so an AI (or this script) can
tell whether the index is stale.

  python tools/build_boot_index.py --write   # regenerate
  python tools/build_boot_index.py --check   # exit 1 if stale or invalid
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CURRENT = ROOT / "governance" / "CURRENT.json"
INDEX = ROOT / "governance" / "BOOT_INDEX.json"


def git_blob_sha(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def build() -> dict:
    raw = CURRENT.read_bytes()
    cur = json.loads(raw)
    errors = []
    routes = cur.get("task_routes", [])
    seen = set()
    for r in routes:
        rid = r.get("id")
        if not rid or rid in seen:
            errors.append("duplicate or missing route id: %r" % rid)
        seen.add(rid)
        for p in r.get("load", []):
            if not (ROOT / p).is_file():
                errors.append("route %s loads missing file: %s" % (rid, p))
    for k, p in cur.get("rules", {}).items():
        if not (ROOT / p).is_file():
            errors.append("rules.%s points to missing file: %s" % (k, p))
    if errors:
        raise SystemExit("CURRENT.json problems:\n  " + "\n  ".join(errors))

    features = cur.get("features", {})
    pointers = {k: v for k, v in cur.get("rules", {}).items()
                if k != "persona" or features.get("persona_enabled")}
    pointers["records_dir"] = cur.get("records_dir")
    return {
        "kind": "DERIVED_INDEX__NOT_THE_SOURCE",
        "source": "governance/CURRENT.json",
        "current_blob_sha": git_blob_sha(raw),
        "freshness_rule": "Valid only while current_blob_sha equals the git blob SHA of governance/CURRENT.json. If it differs or cannot be checked, read CURRENT.json directly.",
        "status": cur.get("status"),
        "version": cur.get("version"),
        "features": features,
        "pointers": pointers,
        "precedence": cur.get("precedence", []),
        "task_routes": [{"id": r["id"], "when": r.get("when", ""), "load": r.get("load", [])}
                        for r in routes
                        if r["id"] != "PERSONA" or features.get("persona_enabled")],
        "generator": "tools/build_boot_index.py",
    }


def render(obj: dict) -> str:
    return json.dumps(obj, ensure_ascii=False, indent=2) + "\n"


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true")
    g.add_argument("--check", action="store_true")
    a = ap.parse_args()
    new = render(build())
    old = INDEX.read_text("utf-8") if INDEX.exists() else ""
    if a.check:
        if new != old:
            print("BOOT_INDEX.json is stale. Run: python tools/build_boot_index.py --write")
            sys.exit(1)
        print("BOOT_INDEX.json is fresh.")
        return
    if new != old:
        INDEX.write_text(new, "utf-8")
        print("BOOT_INDEX.json updated.")
    else:
        print("BOOT_INDEX.json already fresh.")


if __name__ == "__main__":
    main()
