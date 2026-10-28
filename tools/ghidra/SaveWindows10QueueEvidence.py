"""Retain literal, source-byte-checked excerpts for the Windows 10 queue investigation.

Run after the matching-PDB exports described in docs/windows10-queue-identity.md.
This reads binaries as data; it neither executes nor patches them.
"""
import hashlib
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[2]
SETS = [
    ("win10-driver-analysis", "artifacts/acquisition/win10-community-20261028/reconstructed/xinputhid.sys",
     "c358e6cfa3492d1d228ac855fb3593b6dc363ee41e3797f8bff380a0458a4a0f",
     ["1c0009068", "1c0003240", "1c000a190", "1c0006dc0"]),
    ("xinputhid-analysis", "C:/Windows/System32/drivers/xinputhid.sys",
     "1e85d1a191f09ed62645658c94f908b733da5a026ed2b6b662635ebbddf84588", ["14000d1d8"]),
    ("win10-inbox-analysis", "artifacts/acquisition/win10-community-20261028/gameinputinbox.dll",
     "b7d2fc1ec42dbd00c3dddb077ab32e7e5f84288b9c7e7dcafed324150b5242f7",
     ["18003b524", "18003b758"]),
    ("win10-xinput-analysis", "artifacts/acquisition/win10-community-20261028/reconstructed/xinput1_4.dll",
     "afcef57f5c6068cedb49ddb370a8d070867fd47fcc8a67fd11694053885dec8d",
     ["10004e01", "10004efc"]),
]


def pe_mapping(data):
    pe = struct.unpack_from("<I", data, 0x3c)[0]
    if data[pe:pe+4] != b"PE\0\0":
        raise ValueError("Not PE")
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    if magic not in (0x10b, 0x20b):
        raise ValueError("Unsupported optional header")
    base = struct.unpack_from("<Q" if magic == 0x20b else "<I", data, opt + (24 if magic == 0x20b else 28))[0]
    section_table = opt + struct.unpack_from("<H", data, pe+20)[0]
    sections = [struct.unpack_from("<III", data, section_table+40*i+12)
                for i in range(struct.unpack_from("<H", data, pe+6)[0])]
    return base, sections


def main():
    records = []
    lines = ["Literal headless Ghidra 12.1.3 exports; not original source.",
             "Pseudocode and instruction text are unchanged. All exported instruction bytes were checked against the pinned PE.",
             "External calls, indirect targets and decompiler types retain the limitations described in the research note."]
    for directory, binary, expected, entries in SETS:
        path = ROOT / binary
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f"Unexpected binary identity: {binary}")
        base, sections = pe_mapping(data)
        for entry in entries:
            export = ROOT / "artifacts" / directory / (entry + ".txt")
            raw = export.read_bytes()
            text = raw.decode("utf-8")
            if "DECOMPILATION completed=true error=" not in text:
                raise ValueError(f"Incomplete export: {export}")
            count = 0
            for line in text.splitlines():
                match = re.match(r"^([0-9a-f]+) ([0-9a-f]+) ", line)
                if not match:
                    continue
                rva = int(match[1], 16) - base
                offsets = [offset+rva-va for va, size, offset in sections if va <= rva < va+size]
                code = bytes.fromhex(match[2])
                if len(offsets) != 1 or data[offsets[0]:offsets[0]+len(code)] != code:
                    raise ValueError(f"Instruction mismatch: {line}")
                count += 1
            if not count:
                raise ValueError("No verified instructions")
            records.append({"binary_sha256": expected, "entry": "0x"+entry,
                            "export": export.relative_to(ROOT).as_posix(),
                            "export_sha256": hashlib.sha256(raw).hexdigest(),
                            "verified_instructions": count})
            lines.extend(["", "=== " + directory + " / " + expected + " ===", text])
    out = ROOT / "evidence/static/windows10-queue-identity-excerpts.txt"
    out.write_bytes("\n".join(lines).encode("utf-8"))
    record = {"evidence_kind": "local-ghidra-static-excerpts", "observed_date": "2026-10-28",
              "runtime_observed": False, "files": records,
              "excerpts_sha256": hashlib.sha256(out.read_bytes()).hexdigest(),
              "limitations": ["Static evidence does not measure the contributor's live queue count or prove FPS causation.",
                              "XInput contributor whole-file hash is unavailable; trace version and PE/PDB identities match.",
                              "Windows 11 comparison applies only to the pinned 10.0.26100.9278 image."]}
    out.with_name("windows10-queue-identity.json").write_text(json.dumps(record, indent=2)+"\n", encoding="utf-8")
    print(f"Verified {sum(r['verified_instructions'] for r in records)} instructions across {len(records)} exports")


if __name__ == "__main__":
    main()
