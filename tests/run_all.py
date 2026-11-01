#!/usr/bin/env python3
"""Run all ai-triage tests (both Python checks and Lua unit tests)."""

import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def main():
    env = {**os.environ, "TZ": "America/New_York"}
    failed = 0
    total = 0

    print("== Running check_ai_usagebar.py ==")
    res = subprocess.run([sys.executable, str(REPO_ROOT / "tests/check_ai_usagebar.py")], env=env, cwd=REPO_ROOT)
    total += 1
    if res.returncode != 0:
        failed += 1
        print("FAIL: check_ai_usagebar.py\n")

    lua_bin = "lua"
    lua_tests = sorted(t for t in (REPO_ROOT / "tests").glob("*.lua") if t.name != "report.lua")
    for test in lua_tests:
        total += 1
        print(f"== Running {test.name} ==")
        res = subprocess.run([lua_bin, str(test)], env=env, cwd=REPO_ROOT)
        if res.returncode != 0:
            failed += 1
            print(f"FAIL: {test.name}")

    print(f"\n==========================================")
    print(f"Results: {total - failed}/{total} test suites passed.")
    if failed:
        sys.exit(1)
    print("All ai-triage tests passed successfully!")


if __name__ == "__main__":
    main()
