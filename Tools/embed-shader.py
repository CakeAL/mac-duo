#!/usr/bin/env python3
"""Regenerates Sources/MacDuoCore/Render/EmbeddedShader.swift from MetalFrost.metal.

The Xcode Metal toolchain (the offline `metal` / `metallib` binaries) is an
optional download, so MacDuo compiles its shaders at run time from this embedded
copy. build.sh regenerates the file on every build; never edit it by hand.
"""
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
source = root / "Sources/MacDuoCore/Render/MetalFrost.metal"
target = root / "Sources/MacDuoCore/Render/EmbeddedShader.swift"

shader = source.read_text(encoding="utf-8")
if '"""' in shader:
    sys.exit("shader source contains a triple quote; escape it before embedding")

target.write_text(
    "//\n"
    "//  EmbeddedShader.swift  —  GENERATED FILE, DO NOT EDIT\n"
    "//\n"
    "//  Produced by Tools/embed-shader.py from MetalFrost.metal so the shader can\n"
    "//  be compiled at run time, without the optional Xcode Metal toolchain.\n"
    "//\n"
    "\n"
    "enum EmbeddedShader {\n"
    '    static let source = """\n'
    f"{shader}"
    '"""\n'
    "}\n",
    encoding="utf-8",
)
print(f"wrote {target.relative_to(root)} ({len(shader)} bytes)")
