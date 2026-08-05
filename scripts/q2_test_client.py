#!/usr/bin/env python3
"""
Minimal Quake II protocol-34 client, just enough to:
  1. complete the OOB getchallenge/connect handshake (allocates a real
     client slot server-side and invokes the game DLL's ClientConnect)
  2. open the classic ("old") netchan and correctly ack packets
  3. receive q2admin's post-connect version-check svc_stufftext
  4. answer it with a matching clc_stringcmd, which is what actually
     triggers CA_PlayerConnect() -> the exact code path that was fixed
  5. optionally send a clean "disconnect" stringcmd afterward

Packet formats taken directly from q2pro source (same commit pinned in
the project's Dockerfile), not from memory:
  - src/server/main.c: SVC_GetChallenge, SVC_DirectConnect, parse_basic_params
  - src/common/net/chan.c: NetchanOld_Transmit / NetchanOld_Process
  - inc/common/protocol.h: svc_ops_t / clc_ops_t enum values
"""
import socket
import struct
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 27923
QPORT = 4242
PROTOCOL = 34

# svc_ (server->client) opcodes
svc_nop = 6
svc_disconnect = 7
svc_reconnect = 8
svc_print = 10
svc_stufftext = 11

# clc_ (client->server) opcodes
clc_stringcmd = 4

REL_BIT = 1 << 31
OLD_MASK = REL_BIT - 1


def oob(payload: bytes) -> bytes:
    return b"\xff\xff\xff\xff" + payload


class NetchanState:
    def __init__(self):
        self.outgoing_sequence = 1
        self.incoming_sequence = 0
        self.reliable_sequence = 0            # my toggle bit
        self.incoming_reliable_sequence = 0   # server's toggle bit, as last seen
        self.reliable_buf = b""               # pending reliable payload awaiting ack
        self.last_reliable_outseq = None

    def build_packet(self, unreliable: bytes = b"") -> bytes:
        w1 = self.outgoing_sequence & OLD_MASK
        send_reliable = bool(self.reliable_buf)
        if send_reliable:
            w1 |= REL_BIT
        w2 = self.incoming_sequence & OLD_MASK
        if self.incoming_reliable_sequence:
            w2 |= REL_BIT
        pkt = struct.pack("<II", w1, w2)
        pkt += struct.pack("<H", QPORT)
        if send_reliable:
            pkt += self.reliable_buf
            self.last_reliable_outseq = self.outgoing_sequence
        pkt += unreliable
        self.outgoing_sequence += 1
        return pkt

    def queue_reliable(self, payload: bytes):
        # only one in flight at a time here - fine for this script's needs
        self.reliable_buf = payload
        self.reliable_sequence ^= 1

    def process_incoming(self, data: bytes):
        sequence, sequence_ack = struct.unpack_from("<II", data, 0)
        reliable_message = bool(sequence & REL_BIT)
        reliable_ack = bool(sequence_ack & REL_BIT)
        sequence &= OLD_MASK
        sequence_ack &= OLD_MASK

        if sequence <= self.incoming_sequence and self.incoming_sequence != 0:
            return None  # stale/duplicate

        if reliable_ack == bool(self.reliable_sequence) and self.reliable_buf:
            # peer has acked our pending reliable payload
            self.reliable_buf = b""

        self.incoming_sequence = sequence
        if reliable_message:
            self.incoming_reliable_sequence ^= 1

        return data[8:]


def parse_messages(payload: bytes):
    """Yield (opcode, extra) for the small set of opcodes we understand.
    Stops at the first opcode we don't know how to skip past safely -
    we've already updated netchan sequence state by then regardless."""
    i = 0
    out = []
    while i < len(payload):
        cmd = payload[i]
        i += 1
        if cmd == svc_nop:
            out.append((cmd, None))
            continue
        if cmd in (svc_disconnect, svc_reconnect):
            out.append((cmd, None))
            return out
        if cmd == svc_print:
            i += 1  # print level byte
            end = payload.index(b"\x00", i)
            out.append((cmd, payload[i:end].decode(errors="replace")))
            i = end + 1
            continue
        if cmd == svc_stufftext:
            end = payload.index(b"\x00", i)
            out.append((cmd, payload[i:end].decode(errors="replace")))
            i = end + 1
            continue
        out.append(("unknown", cmd))
        return out
    return out


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    target = (HOST, PORT)

    print(f"[*] Sending getchallenge to {target}", flush=True)
    s.sendto(oob(b"getchallenge"), target)
    data, _ = s.recvfrom(4096)
    text = data[4:].decode(errors="replace")
    print(f"[<] {text!r}")
    assert text.startswith("challenge "), "did not get a challenge reply"
    challenge = text.split()[1]

    userinfo = (
        r"\name\CrashfixTestBot\rate\25000\skin\male/grunt"
        r"\hand\0\fov\90\msg\1\gender\male\spectator\0"
    )
    connect_str = f'connect {PROTOCOL} {QPORT} {challenge} "{userinfo}"'
    print(f"[*] Sending: {connect_str}")
    s.sendto(oob(connect_str.encode()), target)
    data, _ = s.recvfrom(4096)
    text = data[4:].decode(errors="replace")
    print(f"[<] {text!r}")
    assert text.startswith("client_connect"), f"connect rejected: {text!r}"
    print(f"[+] t={time.time():.1f} Connected - engine allocated a real client "
          f"slot and called the game DLL's ClientConnect()", flush=True)

    nc = NetchanState()

    # initial ack so the server sees us as alive
    s.sendto(nc.build_packet(), target)

    def drain_for(seconds):
        """Read+ack whatever the server sends for a while, without trying
        to fully parse svc_serverdata/configstring/spawnbaseline floods -
        netchan sequence tracking only depends on the 8-byte header, so
        this is safe even though we can't interpret the payload."""
        t_end = time.time() + seconds
        while time.time() < t_end:
            try:
                data, _ = s.recvfrom(4096)
            except socket.timeout:
                s.sendto(nc.build_packet(), target)
                continue
            nc.process_incoming(data)
            if not nc.reliable_buf:
                s.sendto(nc.build_packet(), target)

    # Send "new" so the engine takes us from cs_assigned to cs_primed.
    # SV_New_f() also stuffs its OWN silent version probe
    # ("cmd \177c version $version\n") - a real client's "cmd" command
    # forwards that verbatim to the server after expanding $version, and
    # the server matches literal command "\177c" (SV_CvarResult_f) to set
    # client->version_string. SV_Begin_f() refuses (drops the client!) if
    # version_string is unset, so we proactively send the exact reply the
    # engine is waiting for - no need to parse the incoming stufftext to
    # know this, the format is fixed and read straight from q2pro source.
    nc.queue_reliable(bytes([clc_stringcmd]) + b"new\x00")
    s.sendto(nc.build_packet(), target)
    print(f"[>] t={time.time():.1f} Sent 'new'", flush=True)
    drain_for(2.0)

    nc.queue_reliable(bytes([clc_stringcmd]) + b"\x7fc version crashfix-test-client-1.0\x00")
    s.sendto(nc.build_packet(), target)
    print(f"[>] t={time.time():.1f} Sent engine version-probe reply", flush=True)
    drain_for(2.0)

    nc.queue_reliable(bytes([clc_stringcmd]) + b"begin\x00")
    s.sendto(nc.build_packet(), target)
    print(f"[>] t={time.time():.1f} Sent 'begin'", flush=True)
    drain_for(2.5)
    print(f"[*] t={time.time():.1f} Should now be a fully spawned in-game client", flush=True)

    version_token = None
    stringcmd_sent = False
    total_runtime = float(sys.argv[3]) if len(sys.argv) > 3 else 15
    deadline = time.time() + total_runtime
    disconnect_sent = False

    pktnum = 0
    while time.time() < deadline:
        try:
            data, _ = s.recvfrom(4096)
        except socket.timeout:
            print(f"[*] t={time.time():.1f} (timeout waiting for next packet, re-acking)", flush=True)
            s.sendto(nc.build_packet(), target)
            continue

        pktnum += 1
        if pktnum <= 5 or pktnum % 20 == 0:
            print(f"[recv #{pktnum}] t={time.time():.1f} {len(data)} bytes: {data[:80].hex()}", flush=True)

        payload = nc.process_incoming(data)
        if payload is None:
            continue
        if payload:
            print(f"    -> payload after 8-byte header: {len(payload)} bytes: {payload[:120]!r}", flush=True)

        for opcode, extra in parse_messages(payload):
            if opcode == svc_print:
                print(f"[svc_print] {extra!r}")
            elif opcode == svc_stufftext:
                print(f"[svc_stufftext] {extra!r}")
                if not stringcmd_sent and "$version" in extra:
                    version_token = extra.split()[0]
                    print(f"[*] Captured version-check token: {version_token!r}")
            elif opcode == svc_disconnect:
                print("[svc_disconnect] server dropped us")
                deadline = 0
                break
            elif opcode == "unknown":
                print(f"[?] unrecognized opcode {extra} in this packet "
                      f"(fine - not needed for this test)")

        if version_token and not stringcmd_sent:
            reply = f"{version_token} crashfix-test-client-1.0\x00".encode()
            nc.queue_reliable(bytes([clc_stringcmd]) + reply)
            s.sendto(nc.build_packet(), target)
            print(f"[>] Sent clc_stringcmd reply: "
                  f"{version_token!r} crashfix-test-client-1.0 "
                  f"(this should trigger CA_PlayerConnect on the server)")
            stringcmd_sent = True
            # give the server a few seconds to process + report to cloud
            deadline = time.time() + 8
            continue

        # keep acking so the server's reliable retransmit logic is happy
        if not nc.reliable_buf:
            s.sendto(nc.build_packet(), target)

    if not disconnect_sent:
        time.sleep(0.5)
        nc.queue_reliable(bytes([clc_stringcmd]) + b"disconnect\x00")
        s.sendto(nc.build_packet(), target)
        print(f"[>] t={time.time():.1f} Sent clean disconnect", flush=True)
        disconnect_sent = True
        time.sleep(1)

    print(f"[SUMMARY] version_token_captured={bool(version_token)} "
          f"stringcmd_sent={stringcmd_sent} disconnect_sent={disconnect_sent}")


if __name__ == "__main__":
    main()
