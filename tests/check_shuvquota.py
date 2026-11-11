#!/usr/bin/env python3
"""Run Shuvquota regressions; --live also checks the local API through bar/panel.

No credentials are read. Live public snapshots are held only in private temporary
files. The default invocation is offline.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request

from check_ai_usagebar import lua


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    env = {**os.environ, "TZ": "America/New_York"}
    subprocess.run(["lua", "tests/shuvquota_test.lua"], cwd=root, env=env, check=True)
    if not args.live:
        return
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open("http://127.0.0.1:4789/api/quota", timeout=35) as response:
        raw = response.read(1048577)
    assert len(raw) <= 1048576, "oversized collector response"
    snapshot = json.loads(raw)
    assert snapshot["schemaVersion"] == 2 and snapshot["complete"] is True
    with tempfile.TemporaryDirectory(prefix="ai-triage-shuvquota-") as directory:
        path = Path(directory) / "snapshot.lua"
        path.write_text("return " + lua(snapshot))
        path.chmod(0o600)
        subprocess.run(["lua", "tests/compatibility_test.lua", str(path), "shuvquota"],
                       cwd=root, env=env, check=True)
    for provider in snapshot["providers"]:
        print(f"live: {provider['id']} accounts={len(provider['accounts'])} "
              f"statuses={','.join(a['status'] for a in provider['accounts'])}")


if __name__ == "__main__":
    main()
