#!/usr/bin/env python3
"""Generate golden fixtures for BourassEngineTests.

Mirrors the wire format implemented in Swift (per-chunk AES-GCM, Format A —
the libfaizvpn.so / Go-server primary path). Deterministic: fixed IVs,
fixed inputs. Run from the repo root:

    python3 Tests/BourassEngineTests/make_fixtures.py
"""
import hashlib, hmac, json, os, struct
import zstandard as zstd
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MASTER = bytes.fromhex("3529de18502ac35a534ce8b541d834228ca3c1cd89b6ce3d31cf44072f0e477a")
CERT = "c39a8841ecb915f1ba6462f486ee009219b052db290f5209f53d34c31c56ab41"
TOKEN = "6ae92400e940e8720c737c0b2299ffc3b163625c"
SUB = "b3a88f01e8a54043"
ZONE = "dns.marocdns.uk"
B32 = "abcdefghijklmnopqrstuvwxyz234567"


def b32(d):
    o, b, n = [], 0, 0
    for x in d:
        b = (b << 8) | x
        n += 8
        while n >= 5:
            n -= 5
            o.append(B32[(b >> n) & 31])
    if n:
        o.append(B32[(b << (5 - n)) & 31])
    return "".join(o)


def build_query(name, qtype, txid, opt=None):
    q = struct.pack(">HHHHHH", txid, 0x0100, 1, 0, 0, 1 if opt else 0)
    for lab in name.strip(".").split("."):
        q += bytes([len(lab)]) + lab.encode()
    q += b"\0" + struct.pack(">HH", qtype, 1)
    if opt:
        d = opt.encode()
        q += b"\0" + struct.pack(">HHIH", 41, 1232, 0, 4 + len(d))
        q += struct.pack(">HH", 0xFDE9, len(d)) + d
    return q


def main():
    fx = {}

    # --- identity derivation
    install_id = hashlib.sha256(("fv-install-bind-v1:" + SUB).encode()).hexdigest()[:32]
    hwid = install_id[:16]
    sub_key = hmac.new(MASTER, SUB.encode(), hashlib.sha256).digest()
    sid = "0123456789abcdef0123456789abcdef"
    hs_key_v2 = hmac.new(sub_key, b"hs1\0" + hwid.encode() + b"\0" + CERT.encode(), hashlib.sha256).digest()
    hs_key_v1 = hmac.new(sub_key, b"hs1\0" + install_id.encode() + b"\0" + CERT.encode(), hashlib.sha256).digest()
    sess_key_v2 = hmac.new(sub_key, (hwid + "\0" + sid + "\0" + CERT).encode(), hashlib.sha256).digest()
    sess_key_v1 = hmac.new(sub_key, (install_id + "\0" + sid + "\0" + CERT).encode(), hashlib.sha256).digest()
    fx["identity"] = {
        "installId": install_id, "hwid": hwid, "subId": SUB,
        "subKey": sub_key.hex(), "sid": sid,
        "hsKeyV2": hs_key_v2.hex(), "hsKeyV1": hs_key_v1.hex(),
        "sessionKeyV2": sess_key_v2.hex(), "sessionKeyV1": sess_key_v1.hex(),
    }

    # --- v2 handshake payload + query
    p = bytearray(27)
    p[0] = 0x13
    p[1:3] = struct.pack(">H", 122)
    p[3:11] = bytes.fromhex(SUB)[:8]
    p[11:19] = bytes.fromhex(hwid)[:8]
    p[19:23] = bytes.fromhex(CERT)[:4]
    p[23:27] = bytes.fromhex(TOKEN)[4:8]
    v2_qname = "0h." + b32(bytes(p)) + "." + ZONE
    fx["v2"] = {
        "payloadHex": bytes(p).hex(),
        "payloadB32": b32(bytes(p)),
        "qname": v2_qname,
        "queryHex": build_query(v2_qname, 10, 0x2AB7, TOKEN).hex(),
    }

    # --- v1 handshake query
    v1_qname = ("0-handshake-batch-zstd.%s.%s.0.110.%s.%s.%s."
                % (SUB, install_id, CERT[:32], CERT[32:], ZONE))
    fx["v1"] = {"qname": v1_qname, "queryHex": build_query(v1_qname, 10, 0x2AB7).hex()}

    # --- base32 vectors (all computed, never hand-written)
    fx["base32"] = [
        {"in": "", "out": ""},
        {"in": "f0", "out": b32(bytes.fromhex("f0"))},
        {"in": "f0ba", "out": b32(bytes.fromhex("f0ba"))},
        {"in": bytes(p).hex(), "out": b32(bytes(p))},
        {"in": bytes(range(16)).hex(), "out": b32(bytes(range(16)))},
    ]

    # --- poll query
    poll_qname = "0-poll.39928.7.424242.s10.8.80.2.%s." % ZONE
    fx["poll"] = {"qname": poll_qname, "queryHex": build_query(poll_qname, 10, 0x0042).hex()}

    # --- uplink (Format A: per-chunk encryption, fixed IVs)
    def randblock(seed, n):  # deterministic, incompressible
        out = b""
        c = seed
        while len(out) < n:
            out += hashlib.sha256(str(c).encode()).digest()
            c += 1
        return out[:n]

    pkt1 = b"\x45\x00" + randblock(1, 79)           # 81 B
    pkt2 = b"\x45\x00" + randblock(2, 118)          # 120 B
    pkt3 = b"\x45\x00" + randblock(3, 300)          # 302 B
    packets = [pkt1, pkt2, pkt3]
    body = b"".join(struct.pack(">H", len(x)) + x for x in packets)
    z = zstd.ZstdCompressor(level=1).compress(body)
    n = (len(z) + 80) // 81
    ivs = [bytes([0x10 + i]) * 12 for i in range(n)]
    def split_labels(b):
        parts = [b[j:j + 60] for j in range(0, len(b), 60)]
        return ["%d-%s" % (k, p) for k, p in enumerate(parts)]

    chunks, labels, qnames = [], [], []
    for i in range(n):
        piece = z[i * 81:(i + 1) * 81]
        chunk = struct.pack(">HBB", 300, i, n) + b"\xf1" + ivs[i] + AESGCM(sess_key_v2).encrypt(ivs[i], piece, None)
        chunks.append(chunk.hex())
        labels.append(split_labels(b32(chunk)))
        qnames.append(".".join(split_labels(b32(chunk))) + ".s" + sid + "." + ZONE)
    fx["uplink"] = {
        "packets": [x.hex() for x in packets], "seq": 300, "sid": sid, "zone": ZONE,
        "sessionKey": sess_key_v2.hex(), "ivs": [i.hex() for i in ivs],
        "chunkCount": n, "chunkHex": chunks, "qnames": qnames,
        "queryHex": [build_query(q, 10, 0x0777).hex() for q in qnames],
    }

    # --- downlink (server style: one envelope, fixed iv)
    d_pkts = [b"\x45\x00" + b"\xCC" * 100, b"\x45\x00" + b"\xDD" * 60]
    d_body = b"".join(struct.pack(">H", len(x)) + x for x in d_pkts)
    d_z = zstd.ZstdCompressor(level=1).compress(d_body)
    d_iv = bytes.fromhex("deadbeef" * 3)
    d_rdata = b"\xf1" + d_iv + AESGCM(sess_key_v2).encrypt(d_iv, d_z, None)
    # full DNS response like the Go server's buildResponse (answer = qname ptr + NULL rr)
    q = build_query("0-poll.39928.1.1.s10.8.80.2." + ZONE, 10, 0x0777)
    resp = struct.pack(">HHHHHH", 0x0777, 0x8180, 1, 1, 0, 0) + q[12:] \
        + b"\xc0\x0c" + struct.pack(">HHIH", 10, 1, 1, len(d_rdata)) + d_rdata
    fx["downlink"] = {
        "packets": [x.hex() for x in d_pkts],
        "sessionKey": sess_key_v2.hex(),
        "rdataHex": d_rdata.hex(),
        "responseHex": resp.hex(),
    }

    out = os.path.join(os.path.dirname(__file__), "Fixtures", "golden.json")
    with open(out, "w") as f:
        json.dump(fx, f, indent=1)
    print("wrote", out, "chunks:", n)


if __name__ == "__main__":
    main()
