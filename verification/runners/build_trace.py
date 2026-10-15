#!/usr/bin/env python3
"""Build the official simulator with trace and optional top-level parameters.

Uses the framework's file-list parser and FakeRAM source selection without
changing any framework file. Requires native Verilator/C++/Make executables
(or running inside the course Linux container).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from build import read_sources
from fakeram import with_ram_source


def executable(value: str) -> str:
    found = shutil.which(value)
    if not found:
        raise ValueError(f"executable not found: {value}")
    return str(Path(found).resolve())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/verification/trace")
    parser.add_argument("--filelist", type=Path, default=ROOT / "verilog/filelist.f")
    parser.add_argument("--harness", type=Path, default=ROOT / "scripts/sim.cpp",
                        help="verification-only alternative C++ harness; default is the unmodified official simulator")
    parser.add_argument("--param", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--cxx", default="clang++" if platform.system() == "Darwin" else "g++")
    parser.add_argument("--make", default="gmake" if platform.system() == "Darwin" else "make")
    parser.add_argument("--ar", default="ar")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    parameters = {"TRACE": "1"}
    for item in args.param:
        if "=" not in item:
            parser.error("--param requires NAME=VALUE")
        name, value = item.split("=", 1)
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) or not value:
            parser.error(f"invalid parameter {item!r}")
        parameters[name] = value
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    try:
        verilator, compiler, make, ar = map(executable, (args.verilator, args.cxx, args.make, args.ar))
        sources = with_ram_source(read_sources(args.filelist))
    except (ValueError, OSError) as error:
        parser.error(str(error))
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    flags = " ".join(shlex.quote(f"{key}={value}") for key, value in
                     {"CXX": compiler, "LINK": compiler, "AR": ar, "PYTHON3": sys.executable}.items())
    simulator_source = args.harness.resolve()
    if not simulator_source.is_file():
        parser.error(f"missing simulator source {simulator_source}")
    command = [verilator, "--cc", "--exe", "--build", "--trace", "--assert", "-Wall", "-Wno-fatal",
               "--top-module", "student_top", "--Mdir", str(output / "obj"), "-o", str(output / "sim"),
               "-j", str(args.jobs), "-MAKEFLAGS", flags, "-CFLAGS", "-std=c++17",
               *[f"-G{name}={value}" for name, value in parameters.items()],
               *[str(path) for path in sources], str(simulator_source)]
    environment = os.environ.copy()
    environment["MAKE"] = make
    recorded_sources = [*sources, simulator_source]
    if simulator_source != ROOT / "scripts/sim.cpp":
        recorded_sources.append(ROOT / "scripts/sim.cpp")
    record = {"command": command, "parameters": parameters,
              "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in recorded_sources}}
    (output / "build.json").write_text(json.dumps(record, indent=2) + "\n")
    # A failed rebuild must not leave a stale simulator looking current.
    (output / "sim").unlink(missing_ok=True)
    subprocess.run(command, env=environment, check=True)
    print(output / "sim")


if __name__ == "__main__":
    main()
