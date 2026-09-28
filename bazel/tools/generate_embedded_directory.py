#!/usr/bin/env python3
"""Generate assembly-backed embedded-directory accessors.

The input manifest is tab separated:

    logical/path<TAB>execroot/path

Files are concatenated in manifest order into a payload file. A generated
assembly source uses `.incbin` to include that payload through Bazel's normal C
/ assembly toolchain, while generated C and Swift sources expose pointer/size
and per-file offset metadata.
"""

from __future__ import annotations

import argparse
import pathlib
import re
from dataclasses import dataclass


@dataclass(frozen=True)
class Entry:
    logical_path: str
    filesystem_path: pathlib.Path
    offset: int
    count: int


def c_string(value: str) -> str:
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def swift_string(value: str) -> str:
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def symbol(value: str) -> str:
    sanitized = re.sub(r"[^0-9A-Za-z_]", "_", value)
    if not sanitized or sanitized[0].isdigit():
        sanitized = "_" + sanitized
    return sanitized


def load_entries(manifest: pathlib.Path) -> tuple[list[Entry], bytes]:
    pairs = []
    for line_number, line in enumerate(manifest.read_text().splitlines(), start=1):
        if not line.strip():
            continue
        try:
            logical_path, path = line.split("\t", 1)
        except ValueError as error:
            raise ValueError(f"invalid manifest line {line_number}: {line!r}") from error
        pairs.append((logical_path, pathlib.Path(path)))
    return pack_entries(pairs)


def load_directory_entries(root: pathlib.Path) -> tuple[list[Entry], bytes]:
    pairs = [
        (path.relative_to(root).as_posix(), path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    ]
    if not pairs:
        raise ValueError(f"embedded directory {root} contains no files")
    return pack_entries(pairs)


def pack_entries(pairs: list[tuple[str, pathlib.Path]]) -> tuple[list[Entry], bytes]:
    entries: list[Entry] = []
    payload = bytearray()
    for logical_path, path in pairs:
        data = path.read_bytes()
        offset = len(payload)
        payload.extend(data)
        entries.append(Entry(logical_path, path, offset, len(data)))
    return entries, bytes(payload)


def write_assembly(output: pathlib.Path, symbol_name: str, section_name: str, payload_path: str) -> None:
    output.write_text(f"""#if defined(__APPLE__)
.section __DATA,{section_name}
.globl _{symbol_name}_start
_{symbol_name}_start:
.incbin {c_string(payload_path)}
.globl _{symbol_name}_end
_{symbol_name}_end:
#else
.section .rodata.{symbol_name},"a",@progbits
.globl {symbol_name}_start
{symbol_name}_start:
.incbin {c_string(payload_path)}
.globl {symbol_name}_end
{symbol_name}_end:
#endif
""")


def write_c(output: pathlib.Path, symbol_name: str) -> None:
    pointer = f"{symbol_name}_bytes_pointer"
    size = f"{symbol_name}_bytes_size"
    start = f"{symbol_name}_start"
    end = f"{symbol_name}_end"

    output.write_text(f"""#include <stddef.h>
#include <stdint.h>

extern const uint8_t {start}[];
extern const uint8_t {end}[];

const uint8_t *{pointer}(void) {{
  return {start};
}}

size_t {size}(void) {{
  return (size_t)({end} - {start});
}}
""")


def write_swift(output: pathlib.Path, type_name: str, symbol_name: str, entries: list[Entry]) -> None:
    pointer = f"{symbol_name}_bytes_pointer"
    size = f"{symbol_name}_bytes_size"

    entry_lines: list[str] = []
    for entry in entries:
        components = entry.logical_path.split("/") if entry.logical_path else []
        path_expr = "[" + ", ".join(swift_string(component) for component in components) + "]"
        entry_lines.append(
            f"    File(path: {path_expr}, offset: {entry.offset}, count: {entry.count})"
        )

    files = ",\n".join(entry_lines)
    if files:
        files = "\n" + files + "\n  "

    output.write_text(f"""import Foundation

@_silgen_name({swift_string(pointer)})
private func {pointer}() -> UnsafePointer<UInt8>

@_silgen_name({swift_string(size)})
private func {size}() -> Int

enum {type_name} {{
  struct File: Sendable, Equatable {{
    var path: [String]
    var offset: Int
    var count: Int
  }}

  static let files: [File] = [{files}]

  static func bytes(for file: File) -> UnsafeBufferPointer<UInt8> {{
    precondition(file.offset >= 0)
    precondition(file.count >= 0)
    precondition(file.offset + file.count <= {size}())
    return UnsafeBufferPointer(start: {pointer}().advanced(by: file.offset), count: file.count)
  }}

  static func text(for file: File) -> String {{
    String(decoding: bytes(for: file), as: UTF8.self)
  }}
}}
""")


def main() -> None:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--manifest", type=pathlib.Path)
    source.add_argument("--directory-root", type=pathlib.Path)
    parser.add_argument("--swift-out", required=True, type=pathlib.Path)
    parser.add_argument("--c-out", required=True, type=pathlib.Path)
    parser.add_argument("--assembly-out", required=True, type=pathlib.Path)
    parser.add_argument("--payload-out", required=True, type=pathlib.Path)
    parser.add_argument("--type-name", required=True)
    parser.add_argument("--symbol-name", required=True)
    parser.add_argument("--section-name", required=True)
    args = parser.parse_args()

    type_name = symbol(args.type_name)
    symbol_name = symbol(args.symbol_name)
    if args.manifest is not None:
        entries, payload = load_entries(args.manifest)
    else:
        entries, payload = load_directory_entries(args.directory_root)
    args.payload_out.write_bytes(payload)
    write_assembly(args.assembly_out, symbol_name, args.section_name, str(args.payload_out))
    write_c(args.c_out, symbol_name)
    write_swift(args.swift_out, type_name, symbol_name, entries)


if __name__ == "__main__":
    main()
