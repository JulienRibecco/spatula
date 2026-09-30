#!/usr/bin/env python3
"""Run isolated Lua test processes from any working directory (Python stdlib only)."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default="lua", help="Lua/LuaJIT executable or absolute path")
    parser.add_argument("--suite", choices=("all", "core", "compiler", "editor"), default="all")
    parser.add_argument("--benchmarks", action="store_true", help="Include opt-in timing comparisons")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--timeout", type=float, default=90, help="Seconds per test file")
    args = parser.parse_args()
    runtime = shutil.which(args.lua)
    if not runtime:
        parser.error("Lua executable not found: " + args.lua)
    core = sorted(p for p in (ROOT / "tests").glob("*.lua")
                  if (p.name.startswith("test_") or p.name.endswith("_test.lua"))
                  and p.name not in ("editor_integration_test.lua", "sequencer_test.lua"))
    compiler = sorted((ROOT / "compiler/tests").glob("test_*.lua"))
    editor = [ROOT / "tests/editor_integration_test.lua"]
    suites = {"core": core, "compiler": compiler, "editor": editor, "all": core + compiler + editor}
    env = os.environ.copy()
    env["SPATULA_BENCHMARKS"] = "1" if args.benchmarks else "0"
    failed = 0
    for path in suites[args.suite]:
        # Bootstrap comes from the test file; each process gets fresh module state.
        try:
            result = subprocess.run([runtime, str(path)], cwd=ROOT, env=env,
                                    capture_output=True, text=True, timeout=args.timeout)
            output = result.stdout + result.stderr
            # Guard against older test scripts that report failure without an exit code.
            bad = result.returncode != 0 or "✗" in output or re.search(r"\b[1-9]\d* failed\b", output)
        except subprocess.TimeoutExpired:
            output, bad = "Timed out after %s seconds" % args.timeout, True
        failed += bool(bad)
        print(("FAIL " if bad else "PASS ") + str(path.relative_to(ROOT)), flush=True)
        if bad or args.verbose:
            print(output, flush=True)
    print("\n%d files passed, %d failed (%s)" % (len(suites[args.suite]) - failed, failed, args.lua))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
