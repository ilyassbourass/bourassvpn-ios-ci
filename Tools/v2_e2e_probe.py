#!/usr/bin/env python3
"""End-to-end v2 tunnel test: handshake -> TCP SYN uplink -> poll downlink."""
import hashlib, hmac, json, os, socket, struct, sys, time
import zstandard as zstd
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MASTER = bytes.fromhex("3529de18502ac35a534ce8b541d834228ca3c1cd89b6ce3d31cf44072f0e477a")
CERT = "c39a8841ecb915f1ba6462f486ee009219b052db290f5209f53d34c31c56ab41"
TOKEN = "6ae92400e940e8720c737c0b2299ffc3b163625c"
ZONE = "dns.marocdns.uk"
HOST = "37.221.198.37"
SUB = "b3a88f01e8a54043"
B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
CERT_B = bytes.fromhex(CERT)


def b32(data):
    out, buf, bits = [], 0, 0
    for b in data:
        buf = (buf << 8) | b
        bits += 8
        while bits >= 5:
            bits -= 5
            out.append(B32[(buf >> bits) & 31])
    if bits:
        out.append(B32[(buf << (5 - bits)) & 31])
    return "".join(out).lower()


def hx(s):
    s = "".join(c for c in s if c in "0123456789abcdefABCDEF")
    return bytes.fromhex(s)


def flags(comp=2):
    return ((1 << 1) | 16) & 0xFF


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


def recv_exact(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError
        b += c
    return b


def tcp(host, q, timeout=6.0):
    s = socket.create_connection((host, 53), timeout=timeout)
    s.settimeout(timeout)
    s.sendall(struct.pack(">H", len(q)) + q)
    ln = struct.unpack(">H", recv_exact(s, 2))[0]
    r = recv_exact(s, ln)
    s.close()
    return r


def skip_name(m, o):
    while True:
        l = m[o]
        if l == 0:
            return o + 1
        if l & 0xC0 == 0xC0:
            return o + 2
        o += 1 + l


def answers(m):
    qd, an = struct.unpack(">HH", m[4:8])
    o = 12
    for _ in range(qd):
        o = skip_name(m, o) + 4
    out = []
    for _ in range(an):
        o = skip_name(m, o)
        t, c, ttl, rl = struct.unpack(">HHIH", m[o:o + 10])
        o += 10
        out.append((t, m[o:o + rl]))
        o += rl
    return out


def csum(b):
    if len(b) % 2:
        b += b"\0"
    s = sum(struct.unpack("!" + "H" * (len(b) // 2), b))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def syn(dst="1.1.1.1", dport=80, src="10.8.0.2"):
    sip = socket.inet_aton(src)
    dip = socket.inet_aton(dst)
    tcp = struct.pack("!HHIIBBHHH", 40000, dport, 1000, 0, 5 << 4, 0x02, 64240, 0, 0)
    pseudo = sip + dip + struct.pack("!BBH", 0, 6, len(tcp))
    tcp = tcp[:16] + struct.pack("!H", csum(pseudo + tcp)) + tcp[18:]
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(tcp), 1, 0, 64, 6, 0, sip, dip)
    ip = ip[:10] + struct.pack("!H", csum(ip)) + ip[12:]
    return ip + tcp


def handshake():
    p = bytearray(27)
    p[0] = flags()
    p[1:3] = struct.pack(">H", 122)
    hw = hashlib.sha256(("fv-install-bind-v1:" + SUB).encode()).hexdigest()[:16]
    p[3:11] = hx(SUB)[:8]
    p[11:19] = hx(hw)[:8]
    p[19:23] = CERT_B[:4]
    p[23:27] = hx(TOKEN)[4:8]
    resp = tcp(HOST, build_query("0h." + b32(bytes(p)) + "." + ZONE, 10,
                                 int(time.time()) & 0xFFFF, TOKEN))
    for t, rd in answers(resp):
        if rd and rd[0] == 0xF1:
            key = hmac.new(hmac.new(MASTER, SUB.encode(), hashlib.sha256).digest(),
                           b"hs1\0" + hw.encode() + b"\0" + CERT.encode(),
                           hashlib.sha256).digest()
            j = json.loads(AESGCM(key).decrypt(rd[1:13], rd[13:], None))
            return hw, j["sid"], j["ip"]
    raise SystemExit("handshake failed")


def key_for(hwid, sid):
    return hmac.new(hmac.new(MASTER, SUB.encode(), hashlib.sha256).digest(),
                    (hwid + "\0" + sid + "\0" + CERT).encode(), hashlib.sha256).digest()


def chunked(payload, seq, size=81):
    batch = struct.pack(">H", len(payload)) + payload
    comp = zstd.ZstdCompressor(level=1).compress(batch)
    iv = os.urandom(12)
    env = b"\xf1" + iv + AESGCM_key.encrypt(iv, comp, None)
    n = (len(env) + size - 1) // size
    out = []
    for i in range(n):
        chunk = struct.pack(">HBB", seq & 0xFFFF, i, n) + env[i * size:(i + 1) * size]
        out.append(b32(chunk))
    return out


def qname_for(chunks, sid):
    return "0-" + ".".join(chunks) + ".s" + sid + "." + ZONE


def poll(sid, ip, n=0):
    name = f"0-poll.39928.{n}.{int(time.time()*1000)%1000000}.s{ip}.{ZONE}"
    return tcp(HOST, build_query(name, 10, int(time.time()) & 0xFFFF))


if __name__ == "__main__":
    hwid, sid, ip = handshake()
    k = key_for(hwid, sid)
    print("sid", sid, "ip", ip)
    import cryptography.hazmat.primitives.ciphers.aead as ae
    AESGCM_key = ae.AESGCM(k)

    pkt = syn(src=ip)
    print("SYN", len(pkt), pkt.hex())
    chunks = chunked(pkt, seq=7)
    print("uplink qname len", len(qname_for(chunks, sid)))

    s = socket.create_connection((HOST, 53), timeout=8)
    s.settimeout(8)

    def send_q(name, qtype=10):
        q = build_query(name, qtype, int(time.time()) & 0xFFFF)
        s.sendall(struct.pack(">H", len(q)) + q)
        ln = struct.unpack(">H", recv_exact(s, 2))[0]
        return recv_exact(s, ln)

    for ci, ch in enumerate(chunks):
        r = send_q(qname_for([ch], sid))
        print("chunk", ci, "resp", len(r),
              [(t, len(rd), rd[:12].hex()) for t, rd in answers(r)])

    got_data = False
    for p in range(8):
        time.sleep(0.4)
        r = poll(sid, ip, p)
        ans = answers(r)
        print("poll", p, "resp", len(r), [(t, len(rd), rd[:12].hex()) for t, rd in ans])
        for t, rd in ans:
            if rd and rd[0] == 0xF1:
                try:
                    pt = AESGCM_key.decrypt(rd[1:13], rd[13:], None)
                    print("  DOWNLINK plain", len(pt), pt[:32].hex())
                    got_data = True
                except Exception as e:
                    print("  decrypt fail", e)
    s.close()
    print("PROBE-DATA" if got_data else "PROBE-EMPTY")
