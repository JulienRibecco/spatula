#!/usr/bin/env python3
"""Build a portable Lua source bundle using an explicit public-file allowlist."""
import argparse
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CORE = ("init", "curve", "signal", "motion", "field", "forms", "distribution",
        "trigger", "point", "audio", "tempo", "util", "json")
COMPILER = ("init.lua", "compiler.lua", "ir.lua", "period.lua", "pool/init.lua",
            "pool/form.lua", "pool/trigger.lua", "pool/distribution.lua",
            "strategies/incremental_rotator.lua", "strategies/lut.lua")
DOCS = ("README.md", "QUICKSTART.md", "CONTRIBUTING.md", "PHILOSOPHY.md",
        "LICENSE", "compiler/README.md", "docs/README.md", "docs/assets/orbit.gif",
        "docs/assets/orbit.png", "docs/assets/orbit.json", "examples/orbit.lua")


def modules():
    """Public module names and source paths, shared by both install checks."""
    result = {"spatula." + name: name + ".lua" for name in CORE}
    result.update({"spatula.compiler." + name[:-4].replace("/", "."):
                   "compiler/" + name for name in COMPILER})
    for name, path in list(result.items()):
        if name.endswith(".init"):
            result[name[:-5]] = path
    return result


def build(output):
    files = {"spatula/" + name + ".lua": ROOT / (name + ".lua") for name in CORE}
    files.update({"spatula/compiler/" + name: ROOT / "compiler" / name for name in COMPILER})
    files.update({name: ROOT / name for name in DOCS})
    # LuaJIT's local search path need not include ?/init.lua. These entry points
    # support ordinary require() without modifying the user's package.path.
    entries = {name: path.read_bytes() for name, path in files.items()}
    for name in list(entries):
        if name.endswith("/init.lua"):
            alias = name[:-len("/init.lua")] + ".lua"
            module = name[:-len(".lua")].replace("/", ".")
            entries[alias] = ('return require("%s")\n' % module).encode()
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, content)
    return output, len(entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/spatula-source.zip")
    args = parser.parse_args()
    path, count = build(args.output)
    print("Built %s (%d files, %d bytes)" % (path, count, path.stat().st_size))


if __name__ == "__main__":
    main()
