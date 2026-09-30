#!/usr/bin/env python3
"""Execute public documentation examples in a fresh source-bundle installation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

from package import ROOT, build, modules

DOCUMENTS = ("README.md", "QUICKSTART.md", "compiler/README.md")


def example_cases():
    recipe = (ROOT / "examples/orbit.lua").read_text().strip()
    readme = (ROOT / "README.md").read_text()
    shown = re.search(r"<!-- orbit-example:start -->\s*```lua\n(.*?)\n```", readme, re.S)
    assert shown and shown.group(1) == recipe, "README orbit differs from examples/orbit.lua"
    metadata = json.loads((ROOT / "docs/assets/orbit.json").read_text())
    assert metadata["sha256"] == hashlib.sha256((ROOT / "examples/orbit.lua").read_bytes()).hexdigest(), \
        "README animation is stale: run tools/render_readme.py"
    cases = [("installed public imports", "\n".join(
        'assert(type(require("%s")) == "table")' % name for name in sorted(modules())))]
    cases.append(("README orbit values and seamless loop", '''
local orbit = dofile("orbit.lua")
local x, y = orbit(0, {})
assert(math.abs(x - 100) < 1e-9 and math.abs(y) < 1e-9)
local x1, y1 = orbit(1, {})
assert(math.abs(math.sqrt(x1*x1 + y1*y1) - 72) < 1e-8)
for i = 0, 40 do
    local ax, ay = orbit(i/10, {})
    local bx, by = orbit(i/10 + 4, {})
    assert(math.abs(ax-bx) < 1e-8 and math.abs(ay-by) < 1e-8)
end
'''))
    for document in DOCUMENTS:
        content = (ROOT / document).read_text()
        blocks = re.findall(r"^```lua\s*\n(.*?)^```\s*$", content, re.M | re.S)
        assert blocks, "No executable examples in " + document
        cases.extend(("%s example %d" % (document, i), code)
                     for i, code in enumerate(blocks, 1))
    return cases


def install_rock(luarocks, runtime, tree, temporary, env):
    """Use LuaRocks itself, then test away from the checkout and user modules."""
    spec = ROOT / "spatula-scm-1.rockspec"
    inspector = temporary / "inspect.lua"
    inspector.write_text('''dofile(arg[1])
for name, path in pairs(build.modules) do print(name .. "\\t" .. path) end
''')
    result = subprocess.run([runtime, str(inspector), str(spec)], env=env,
                            capture_output=True, text=True, check=True)
    manifest = dict(line.split("\t") for line in result.stdout.splitlines())
    assert manifest == modules(), "LuaRocks and source bundle module lists differ"
    version = subprocess.check_output([runtime, "-e", 'io.write((_VERSION:gsub("Lua ", "")))'],
                                      env=env, text=True)
    command = [luarocks, "--lua-version=" + version,
               "--tree=" + str(tree), "--lua-dir=" + str(Path(runtime).parent.parent)]
    subprocess.run(command + ["lint", str(spec)], cwd=ROOT, env=env, check=True)
    subprocess.run(command + ["make", str(spec), "--deps-mode=none", "--no-manifest"],
                   cwd=ROOT, env=env, check=True)
    # Only this fresh tree is visible to the example processes. Preloaded
    # runtime modules such as LuaJIT's ffi still work through normal require().
    lua_dir = tree / "share/lua" / version
    installed = {str(p.relative_to(lua_dir)) for p in lua_dir.rglob("*.lua")}
    expected = set()
    for name, path in manifest.items():
        # LuaRocks preserves init.lua as a directory entry for its module name.
        relative = name.replace(".", "/")
        if Path(path).name == "init.lua" and not name.endswith(".init"):
            expected.add(relative + "/init.lua")
        else:
            expected.add(relative + ".lua")
    assert installed == expected, "Installed module tree differs from the public allowlist"
    env["LUA_PATH"] = str(lua_dir / "?.lua") + ";" + str(lua_dir / "?/init.lua")
    env["LUA_CPATH"] = ""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default="lua", help="Lua/LuaJIT executable or absolute path")
    parser.add_argument("--luarocks", help="Test a real LuaRocks install instead of the source ZIP")
    args = parser.parse_args()
    runtime = shutil.which(args.lua)
    if not runtime:
        parser.error("Lua executable not found: " + args.lua)
    runtime = str(Path(runtime).resolve())
    # Test normal runtime discovery, independent of the developer's Lua setup.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT"))}
    cases = example_cases()
    failed = 0
    with tempfile.TemporaryDirectory(prefix="spatula-install-") as temporary:
        root = Path(temporary)
        project = root / "project"
        project.mkdir()
        if args.luarocks:
            luarocks = shutil.which(args.luarocks)
            if not luarocks:
                parser.error("LuaRocks executable not found: " + args.luarocks)
            install_rock(luarocks, runtime, root / "rocks", root, env)
        else:
            archive, _ = build(root / "spatula.zip")
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(project)
        shutil.copy2(ROOT / "examples/orbit.lua", project / "orbit.lua")
        for name, code in cases:
            path = project / "example.lua"
            path.write_text(code)
            try:
                result = subprocess.run([runtime, str(path)], cwd=project, env=env,
                                        capture_output=True, text=True, timeout=30)
                bad = result.returncode != 0
                output = result.stdout + result.stderr
            except subprocess.TimeoutExpired:
                bad, output = True, "Example timed out"
            failed += bool(bad)
            print(("FAIL " if bad else "PASS ") + name)
            if bad:
                print(output)
    print("\n%d examples/import checks passed, %d failed (%s)" %
          (len(cases) - failed, failed, args.lua))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
