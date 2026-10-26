import Foundation

/// Wire-level helpers: hex, base32 (lowercase RFC4648, no padding — the
/// FastDNS on-wire encoding), DNS query building and answer parsing.
///
/// Byte-for-byte port of FastDnsEngine.kt companion functions; goldens in
/// Tests/BourassEngineTests/Fixtures prove parity with the Kotlin engine.
public enum Wire {

    static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    // MARK: hex

    public static func hexToBytes(_ hex: String) -> [UInt8] {
        let chars = hex.filter { $0.isHexDigit }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = chars.startIndex
        while i < chars.endIndex, chars.index(after: i) < chars.endIndex {
            let hi = chars[i].hexDigitValue ?? 0
            let lo = chars[chars.index(after: i)].hexDigitValue ?? 0
            out.append(UInt8((hi << 4) | lo))
            i = chars.index(i, offsetBy: 2)
        }
        return out
    }

    public static func bytesToHex(_ bytes: [UInt8]) -> String {
        let table = Array("0123456789abcdef")
        var s = ""
        s.reserveCapacity(bytes.count * 2)
        for b in bytes {
            s.append(table[Int(b >> 4)])
            s.append(table[Int(b & 0x0F)])
        }
        return s
    }

    // MARK: base32 (lowercase, no padding) — matches Kotlin base32Encode / Go b32Enc

    public static func base32Encode(_ data: [UInt8]) -> String {
        var sb = ""
        sb.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer = 0
        var bits = 0
        for b in data {
            buffer = (buffer << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                sb.append(base32Alphabet[(buffer >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            sb.append(base32Alphabet[(buffer << (5 - bits)) & 0x1F])
        }
        return sb
    }

    public static func base32Decode(_ s: String) -> [UInt8]? {
        let alphabet = "abcdefghijklmnopqrstuvwxyz234567"
        var buffer = 0
        var bits = 0
        var out = [UInt8]()
        for c in s.lowercased() {
            guard let idx = alphabet.firstIndex(of: c) else { return nil }
            let v = alphabet.distance(from: alphabet.startIndex, to: idx)
            buffer = (buffer << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return out
    }

    // MARK: DNS query (TCP-framing payload; the 2-byte length prefix is added by the writer)

    /// Port of Kotlin buildDnsQuery: qname labels, QTYPE (default 10 NULL), QCLASS IN,
    /// optional EDNS0 OPT carrying one option: code 0xFDE9 = session token.
    public static func buildDnsQuery(qname: String, qtype: UInt16 = 10, txid: UInt16 = 0x1234, optData: [UInt8]? = nil) -> [UInt8] {
        let parts = qname.trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".").map(String.init)
        var nameLen = 1
        for p in parts { nameLen += 1 + p.utf8.count }
        let optLen = optData != nil ? 11 + 4 + optData!.count : 0
        var buf = [UInt8](repeating: 0, count: 12 + nameLen + 4 + optLen)

        buf[0] = UInt8(txid >> 8)
        buf[1] = UInt8(txid & 0xFF)
        buf[2] = 0x01 // RD
        buf[3] = 0x00
        buf[4] = 0x00; buf[5] = 0x01 // QDCOUNT
        if let opt = optData {
            buf[10] = 0x00; buf[11] = 0x01 // ARCOUNT
        }

        var off = 12
        for p in parts {
            let bytes = Array(p.utf8)
            buf[off] = UInt8(bytes.count)
            off += 1
            for b in bytes { buf[off] = b; off += 1 }
        }
        buf[off] = 0x00
        off += 1
        buf[off] = UInt8(qtype >> 8); buf[off + 1] = UInt8(qtype & 0xFF)
        off += 2
        buf[off] = 0x00; buf[off + 1] = 0x01 // QCLASS IN
        off += 2

        if let opt = optData {
            buf[off] = 0x00 // root name
            buf[off + 1] = 0x00; buf[off + 2] = 0x29 // TYPE 41 (OPT)
            buf[off + 3] = 0x04; buf[off + 4] = 0xD0 // CLASS 1232
            // TTL 0 (4 bytes) already zero
            let rdLen = 4 + opt.count
            buf[off + 9] = UInt8(rdLen >> 8); buf[off + 10] = UInt8(rdLen & 0xFF)
            buf[off + 11] = 0xFD; buf[off + 12] = 0xE9 // option 65001 = session token
            buf[off + 13] = UInt8(opt.count >> 8); buf[off + 14] = UInt8(opt.count & 0xFF)
            for (i, b) in opt.enumerated() { buf[off + 15 + i] = b }
        }
        return buf
    }

    // MARK: DNS answer parsing

    /// All answer RRs: (type, rdata). Mirrors the Go server's answers layout.
    public static func parseAnswers(_ msg: [UInt8]) -> [(type: UInt16, rdata: [UInt8])] {
        guard msg.count >= 12 else { return [] }
        func u16(_ o: Int) -> Int { (Int(msg[o]) << 8) | Int(msg[o + 1]) }
        let qd = u16(4)
        let an = u16(6)
        var o = 12
        var out: [(UInt16, [UInt8])] = []

        func skipName(_ o: inout Int) {
            while o < msg.count {
                let l = Int(msg[o])
                if l == 0 { o += 1; return }
                if (l & 0xC0) == 0xC0 { o += 2; return }
                o += 1 + l
            }
        }
        for _ in 0..<qd {
            skipName(&o)
            o += 4
        }
        for _ in 0..<an {
            guard o < msg.count else { break }
            skipName(&o)
            guard o + 10 <= msg.count else { break }
            let t = UInt16(u16(o))
            let rdLen = u16(o + 8)
            o += 10
            guard o + rdLen <= msg.count else { break }
            out.append((t, Array(msg[o..<(o + rdLen)])))
            o += rdLen
        }
        return out
    }

    /// First answer rdata (Kotlin parseDnsAnswer semantics).
    public static func parseFirstAnswer(_ msg: [UInt8]) -> [UInt8]? {
        parseAnswers(msg).first?.rdata
    }
}
