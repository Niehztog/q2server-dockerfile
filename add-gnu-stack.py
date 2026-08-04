#!/usr/bin/env python3
"""Add a non-executable PT_GNU_STACK program header to an ELF32 shared object.

Why this exists
---------------
Game DLLs built by pre-2003 toolchains (e.g. arena/gamei386.real.so, a 2014
build using an older toolchain) carry no PT_GNU_STACK header at all. Modern
glibc treats that as "this object needs an executable stack" and asks the
kernel to make the loading process's stack executable at dlopen() time.

q2proded is built by a modern toolchain and is correctly marked
non-executable, so that request becomes a runtime mprotect() - which the
kernel refuses:

    dlopen failed: cannot enable executable stack as shared object requires:
    Invalid argument

Adding an explicit non-exec PT_GNU_STACK header tells glibc no executable
stack is needed, and the dlopen succeeds.

How it works
------------
It appends a brand-new program header table at end-of-file (the original
table plus one PT_GNU_STACK entry) and repoints e_phoff/e_phnum at it. Not a
single existing byte is moved or modified.

Do NOT use `patchelf --clear-execstack` for this instead: it was tried and
silently corrupted this binary, rewriting DT_REL from 0x9ad4 to a value
inside .text and relocating .hash, after which the loader read code as
relocation entries and segfaulted inside ld-linux.so.2.

Usage
-----
    ./add-gnu-stack.py <input.so> <output.so>

Verify afterwards - GNU_STACK must be present with RW (no E), and the
dynamic section must be byte-for-byte what it was:

    readelf -l output.so | grep -A1 GNU_STACK
    readelf -d output.so | grep '(REL)'      # must be unchanged vs input
"""
import struct
import sys

PT_GNU_STACK = 0x6474E551
PF_R, PF_W = 4, 2
EHDR_PHOFF, EHDR_PHNUM = 28, 44  # ELF32 e_phoff / e_phnum byte offsets


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <input.so> <output.so>")
    src, dst = sys.argv[1], sys.argv[2]

    with open(src, "rb") as f:
        data = bytearray(f.read())

    if data[0:4] != b"\x7fELF":
        sys.exit(f"{src}: not an ELF file")
    if data[4] != 1:
        sys.exit(f"{src}: not ELF32 (this script is ELF32-only)")
    if data[5] != 1:
        sys.exit(f"{src}: not little-endian")

    e_phoff, = struct.unpack_from("<I", data, EHDR_PHOFF)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 42)
    if e_phentsize != 32:
        sys.exit(f"{src}: unexpected e_phentsize {e_phentsize}, expected 32")

    for i in range(e_phnum):
        p_type, = struct.unpack_from("<I", data, e_phoff + i * e_phentsize)
        if p_type == PT_GNU_STACK:
            sys.exit(f"{src}: already has a PT_GNU_STACK header, nothing to do")

    phdrs = bytes(data[e_phoff:e_phoff + e_phentsize * e_phnum])
    # p_type, offset, vaddr, paddr, filesz, memsz, flags, align
    new_entry = struct.pack("<IIIIIIII", PT_GNU_STACK, 0, 0, 0, 0, 0, PF_R | PF_W, 16)

    new_phoff = len(data)
    out = bytearray(data) + phdrs + new_entry
    struct.pack_into("<I", out, EHDR_PHOFF, new_phoff)
    struct.pack_into("<H", out, EHDR_PHNUM, e_phnum + 1)

    with open(dst, "wb") as f:
        f.write(out)

    print(f"wrote {dst}: {len(out)} bytes, e_phoff={new_phoff:#x}, e_phnum={e_phnum + 1}")
    print("verify with:  readelf -l %s | grep -A1 GNU_STACK" % dst)


if __name__ == "__main__":
    main()
