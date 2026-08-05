#!/usr/bin/env python3
"""
Validates q2pro .bsp.override files against the exact binary format and
entity-string grammar the engine/game actually use, so a syntax error can be
caught offline instead of crashing SpawnServer on a live map load.

Binary header format, read directly from q2pro source (src/common/cmodel.c,
CM_LoadOverride, commit 601a8df8):
    int32 bits            (OVERRIDE_NAME=1, OVERRIDE_CSUM=2, OVERRIDE_ENTS=4)
    if bits & OVERRIDE_NAME: char[64] name (MAX_QPATH, must contain a NUL)
    if bits & OVERRIDE_CSUM: int32 checksum
    if bits & OVERRIDE_ENTS: int32 len; byte[len] entity string

Entity-string grammar, read directly from q2pro's bundled reference game
source (src/game/g_spawn.c: SpawnEntities/ED_ParseEdict) and tokenizer
(src/shared/shared.c: COM_ParseToken):
    - tokens are whitespace-separated (byte <= 0x20), // and /* */ comments
      are skipped, "..." is a single quoted token
    - top level: repeat { expect '{' or true EOF ; then read key/value pairs
      until '}' }
    - a '}' where a VALUE was expected is exactly the crash this project hit
      ("closing brace without data") - an odd number of tokens between a
      pair of braces, usually from a dropped/duplicated key or value
      somewhere earlier in that entity block
    - matches match on the first character only (key[0] == '}'), not full
      token equality, mirroring the real C code exactly - a malformed token
      like "}nextkey" (missing whitespace) triggers the same error in q2pro.
    - every key and value in every entity block in this whole file corpus is
      always a quoted string - {/} are the only tokens ever read bare. A
      key/value that comes back unquoted is never legitimate content; it
      means an opening quote is missing.

2026-08-05: xdungeon.bsp.override crash-looped xatrix on `map xdungeon`
("ED_ParseEdict: closing brace without data"). First pass: this validator
reported it (and all 268 other .bsp.override files) clean, because a
faithful textbook tokenizer trace shows the actual defect - one
`"volume" 0.8"` missing its opening quote (should be `"volume" "0.8"`) -
reads as a harmless bare token `0.8"` (the stray `"` just gets swept into
the bare word, since `"` is > 0x20) without shifting the key/value count.
That trace was confirmed correct for both this script and hand-tracing the
real COM_Parse C source - yet gdb, breakpointed on the actual deployed
openffa-xatrix game module at the exact `gi.error()` call site, proved the
real binary DOES desync on this exact spot, and fixing just this one quote
(verified via a live A/B test: crashes before, loads clean after) resolved
it. The deployed gamei386.real.so is a preserved pre-existing binary, not
rebuilt from the current source tree, so its actual compiled tokenizer
likely isn't byte-for-byte identical to what's readable on GitHub today -
the exact mechanism wasn't fully nailed down, but the defect itself was:
a key or value that isn't a quoted string. This validator now flags that
directly (see check_quoting below) rather than relying solely on brace
counting, which this incident proved isn't sufficient on its own.
"""
import struct
import sys

OVERRIDE_NAME = 1
OVERRIDE_CSUM = 2
OVERRIDE_ENTS = 4
OVERRIDE_ALL = 7
MAX_QPATH = 64


class ParseError(Exception):
    pass


def read_header(data, path):
    if len(data) < 4:
        raise ParseError("file too short to contain a bits field")
    (bits,) = struct.unpack_from("<i", data, 0)
    if bits & ~OVERRIDE_ALL:
        raise ParseError(f"invalid bits field 0x{bits:x} (has bits outside OVERRIDE_ALL)")
    off = 4
    name = None
    checksum = None
    entstring = None
    if bits & OVERRIDE_NAME:
        if off + MAX_QPATH > len(data):
            raise ParseError("truncated: not enough bytes for the name field")
        raw = data[off:off + MAX_QPATH]
        if b"\x00" not in raw:
            raise ParseError("name field has no NUL terminator within MAX_QPATH")
        name = raw.split(b"\x00", 1)[0].decode("ascii", errors="replace")
        off += MAX_QPATH
    if bits & OVERRIDE_CSUM:
        if off + 4 > len(data):
            raise ParseError("truncated: not enough bytes for the checksum field")
        (checksum,) = struct.unpack_from("<i", data, off)
        off += 4
    if bits & OVERRIDE_ENTS:
        if off + 4 > len(data):
            raise ParseError("truncated: not enough bytes for the entstring length field")
        (length,) = struct.unpack_from("<i", data, off)
        off += 4
        if length <= 0:
            raise ParseError(f"entstring length is {length} (must be > 0)")
        if off + length > len(data):
            raise ParseError(
                f"truncated: entstring claims {length} bytes but only "
                f"{len(data) - off} remain in the file"
            )
        entstring = data[off:off + length]
        off += length
    return bits, name, checksum, entstring


class Tokenizer:
    """Faithful re-implementation of COM_ParseToken over a byte buffer."""

    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0
        self.line = 1

    def next(self):
        """Returns (token:str|None, eof:bool, quoted:bool). eof=True mirrors
        the engine setting *data_p = NULL - i.e. ran out of buffer while
        looking for the START of the next token. A token truncated by
        end-of-buffer (e.g. an unterminated quote) is NOT eof - it matches
        the engine's C-string semantics, where *data_p keeps pointing at the
        trailing NUL rather than becoming NULL. quoted=True iff the token
        was read via the "..." branch (a real key/value token always is;
        only {/} are ever legitimately read bare)."""
        d = self.data
        n = len(d)
        while True:
            while self.pos < n and d[self.pos] <= 0x20:
                if d[self.pos:self.pos + 1] == b"\n":
                    self.line += 1
                self.pos += 1
            if self.pos >= n:
                return None, True, False
            if d[self.pos:self.pos + 2] == b"//":
                self.pos += 2
                while self.pos < n and d[self.pos:self.pos + 1] != b"\n":
                    self.pos += 1
                continue
            if d[self.pos:self.pos + 2] == b"/*":
                self.pos += 2
                while self.pos < n and d[self.pos:self.pos + 2] != b"*/":
                    if d[self.pos:self.pos + 1] == b"\n":
                        self.line += 1
                    self.pos += 1
                self.pos += 2
                continue
            break

        if d[self.pos:self.pos + 1] == b'"':
            self.pos += 1
            start = self.pos
            while self.pos < n and d[self.pos:self.pos + 1] != b'"':
                if d[self.pos:self.pos + 1] == b"\n":
                    self.line += 1
                self.pos += 1
            tok = d[start:self.pos].decode("latin-1")
            if self.pos < n:
                self.pos += 1  # consume closing quote
            return tok, False, True

        start = self.pos
        while self.pos < n and d[self.pos] > 0x20:
            self.pos += 1
        return d[start:self.pos].decode("latin-1"), False, False


def validate_entstring(entstring: bytes):
    """Returns a list of fatal-error strings (empty = clean)."""
    errors = []
    tok = Tokenizer(entstring)
    block_num = 0
    while True:
        line_before = tok.line
        key, eof, _quoted = tok.next()
        if eof:
            break  # normal end of file, matches SpawnEntities' `if (!entities) break;`
        if not key.startswith("{"):
            errors.append(f"line {line_before}: found '{key}' when expecting '{{' "
                           f"(ED_LoadFromFile-equivalent error)")
            break
        block_num += 1
        block_start_line = line_before
        pair_num = 0
        while True:
            key_line = tok.line
            key, eof, key_quoted = tok.next()
            if key.startswith("}"):
                break
            if eof:
                errors.append(f"entity block #{block_num} (starts line {block_start_line}): "
                               f"EOF without closing brace")
                return errors
            if not key_quoted:
                errors.append(
                    f"entity block #{block_num} (starts line {block_start_line}): "
                    f"unquoted key '{key}' at line {key_line} - every real key in this "
                    f"format is a quoted string; this means an opening quote is missing "
                    f"somewhere before it. Same defect class as the 2026-08-05 xdungeon "
                    f"crash (there it was an unquoted VALUE, '\"volume\" 0.8\"' instead of "
                    f"'\"volume\" \"0.8\"') - the deployed game module can desync on this "
                    f"even though a textbook tokenizer trace does not always show a brace "
                    f"mismatch as a result."
                )
                return errors
            val_line = tok.line
            value, eof, value_quoted = tok.next()
            if eof:
                errors.append(f"entity block #{block_num} (starts line {block_start_line}): "
                               f"EOF without closing brace (after key '{key}' at line {key_line})")
                return errors
            if value.startswith("}"):
                errors.append(
                    f"entity block #{block_num} (starts line {block_start_line}): "
                    f"closing brace without data - key '{key}' (line {key_line}) has no "
                    f"matching value; '}}' appears at line {val_line} where a value was "
                    f"expected. This is the exact crash: gi.error(\"ED_ParseEdict: closing "
                    f"brace without data\")."
                )
                return errors
            if not value_quoted:
                errors.append(
                    f"entity block #{block_num} (starts line {block_start_line}): "
                    f"unquoted value '{value}' for key '{key}' at line {val_line} - every "
                    f"real value in this format is a quoted string; this means an opening "
                    f"quote is missing before it. This is the exact defect that caused the "
                    f"2026-08-05 xdungeon crash ('\"volume\" 0.8\"' instead of "
                    f"'\"volume\" \"0.8\"') - a textbook tokenizer trace shows this as a "
                    f"harmless bare token and does not always show a brace mismatch "
                    f"downstream, but the actual deployed game module can still desync on "
                    f"it, confirmed via a live gdb trace and an A/B fix test."
                )
                return errors
            pair_num += 1
    return errors


def main():
    paths = sys.argv[1:]
    if not paths:
        print("usage: validate_override.py <file.bsp.override> [...]", file=sys.stderr)
        sys.exit(2)

    any_bad = False
    for path in paths:
        with open(path, "rb") as f:
            data = f.read()
        try:
            bits, name, checksum, entstring = read_header(data, path)
        except ParseError as e:
            print(f"BAD HEADER  {path}: {e}")
            any_bad = True
            continue

        if entstring is None:
            print(f"ok (no ents) {path}  bits=0x{bits:x} name={name!r} checksum={checksum!r}")
            continue

        errors = validate_entstring(entstring)
        if errors:
            any_bad = True
            print(f"BROKEN      {path}  ({len(entstring)} bytes of entity string)")
            for e in errors:
                print(f"            -> {e}")
        else:
            print(f"ok          {path}  ({len(entstring)} bytes)")

    sys.exit(1 if any_bad else 0)


if __name__ == "__main__":
    main()
