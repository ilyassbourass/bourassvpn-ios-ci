import Foundation

/// The FastDNS v1/v2 wire protocol: handshake construction, key derivation,
/// uplink chunked queries, poll queries, downlink decoding.
///
/// Sources of truth (all three agree):
///  - FastDnsEngine.kt (deployed Android engine)
///  - .freebuff/work/v2_e2e.py + v2_comp_test.py (standalone Python oracles, proven live)
///  - remote_fastdns_srv.go (our Oracle server: primary per-chunk decrypt path)
public enum FastDnsProtocol {

    // MARK: identity derivation

    /// installId = sha256("fv-install-bind-v1:" + sub)[0..32]; hwid = installId[0..16].
    public static func installId(sub: String) -> String {
        String(Crypto.sha256Hex("fv-install-bind-v1:\(sub)").prefix(32))
    }

    public static func hwid(sub: String) -> String {
        String(installId(sub: sub).prefix(16))
    }

    public static func subKey(masterKey: [UInt8], sub: String) -> [UInt8] {
        Crypto.hmacSHA256(key: masterKey, data: Array(sub.utf8))
    }

    /// Handshake response key: HMAC(subKey, "hs1\0" + keyDev + "\0" + CERT-ascii)
    public static func handshakeKey(subKey: [UInt8], keyDev: String, cert: String) -> [UInt8] {
        Crypto.hmacSHA256(key: subKey, data: Array("hs1\0\(keyDev)\0\(cert)".utf8))
    }

    /// Session key: HMAC(subKey, keyDev + "\0" + sid + "\0" + CERT-ascii)
    public static func sessionKey(subKey: [UInt8], keyDev: String, sid: String, cert: String) -> [UInt8] {
        Crypto.hmacSHA256(key: subKey, data: Array("\(keyDev)\0\(sid)\0\(cert)".utf8))
    }

    // MARK: v2 short handshake ("0h.") — Faiz servers

    /// 27-byte payload: [0] flags, [1-2] app version 122 BE, [3-10] sub,
    /// [11-18] hwid, [19-22] cert prefix, [23-26] token bytes 4..8.
    ///
    /// Flag 0x13 (not 0x12): bit0 MUST be set — with 0x12 the server acks
    /// uplinks but never forwards them (verified against the live server).
    public static func buildV2HandshakeQuery(sub: String, hwid: String, cert: String, token: String, zone: String, txid: UInt16) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 27)
        p[0] = 0x13 // v2Flags(compression: 2, z: true, z2: false)
        p[1] = 0
        p[2] = 122
        let subB = Wire.hexToBytes(sub)
        for i in 0..<min(8, subB.count) { p[3 + i] = subB[i] }
        let hwB = Wire.hexToBytes(hwid)
        for i in 0..<min(8, hwB.count) { p[11 + i] = hwB[i] }
        let certB = Wire.hexToBytes(cert)
        for i in 0..<min(4, certB.count) { p[19 + i] = certB[i] }
        let tokB = Wire.hexToBytes(token)
        if tokB.count >= 8 {
            for i in 0..<4 { p[23 + i] = tokB[4 + i] }
        }
        let qname = "0h.\(Wire.base32Encode(p)).\(zone)"
        return Wire.buildDnsQuery(qname: qname, qtype: 10, txid: txid, optData: Array(token.utf8))
    }

    // MARK: v1 long handshake — our Oracle (UDPA v1)

    public static func buildV1HandshakeQuery(sub: String, installId: String, cert: String, zone: String, txid: UInt16) -> [UInt8] {
        let qname = "0-handshake-batch-zstd.\(sub).\(installId).0.110.\(cert.prefix(32)).\(cert.dropFirst(32)).\(zone)."
        return Wire.buildDnsQuery(qname: qname, qtype: 10, txid: txid)
    }

    public enum UplinkFormat {
        /// Per-chunk encryption — libfaizvpn.so behavior (our Go server's
        /// primary path). Each chunk: seq,i,n + 0xf1 + iv_i + ct(piece_i).
        case perChunk
        /// Single envelope sliced into chunks — the format the Freebuff
        /// oracle PROVED end-to-end against Faiz's live server. One
        /// 0xf1+iv+ct(zstd batch), sliced into seq,i,n-framed pieces.
        case singleEnvelope
    }

    /// Splits base32 into wire-legal labels: DNS labels cap at 63 octets
    /// (RFC 1035) — a full chunk's base32 is ~180 chars and gets FORMERR'd by
    /// every resolver (and by our own dotbridge, whose parser rejects length
    /// bytes >= 0x40 as compression pointers). Continuation scheme as parsed
    /// by remote_fastdns_srv.go: `0-<part>.1-<part>.2-<part>…`, prefixes
    /// stripped and parts joined server-side. Matches Faiz's own ≤60-char
    /// labels observed in t7.pcap.
    static func splitB32Labels(_ b32: String, partLen: Int = 60) -> [String] {
        guard !b32.isEmpty else { return [] }
        var parts = [String]()
        var idx = b32.startIndex
        while idx < b32.endIndex {
            let end = b32.index(idx, offsetBy: partLen, limitedBy: b32.endIndex) ?? b32.endIndex
            parts.append(String(b32[idx..<end]))
            idx = end
        }
        return parts.enumerated().map { i, p in "\(i)-\(p)" }
    }

    // MARK: uplink chunked queries

    /// Builds one DNS query per chunk. Wire format (server primary path,
    /// matching libfaizvpn.so): each chunk is independently encrypted.
    ///
    ///   body    = concat( BE16(len(p)) + p for p in packets )
    ///   z       = zstd(body, level 1)
    ///   pieces  = z split into 81-byte slices
    ///   chunk_i = BE16(seq) + u8(i) + u8(n) + 0xf1 + iv_i + AESGCM(key, iv_i, piece_i)
    ///   qname   = "0-" + base32(chunk_i) + ".s" + sid + "." + zone
    public static func buildUplinkQueries(packets: [[UInt8]], seq: UInt16, sid: String, zone: String, sessionKey: [UInt8], txid: UInt16, ivs: [[UInt8]]? = nil, format: UplinkFormat = .perChunk) throws -> [[UInt8]] {
        var body = [UInt8]()
        for p in packets {
            body.append(UInt8(p.count >> 8))
            body.append(UInt8(p.count & 0xFF))
            body.append(contentsOf: p)
        }
        guard let z = Crypto.zstdCompress(body) else {
            throw EngineError.crypto("zstd compress failed — dropping batch")
        }
        let chunkSize = EngineConfig.chunkPayload
        let n = (z.count + chunkSize - 1) / chunkSize

        func qnameFor(_ chunk: [UInt8]) -> String {
            let labels = splitB32Labels(Wire.base32Encode(chunk))
            return labels.joined(separator: ".") + ".s\(sid).\(zone)"
        }

        var queries = [[UInt8]]()
        if format == .singleEnvelope {
            let iv = ivs?.first ?? arc4random_buf_bytes(12)
            let env = try Crypto.gcmSeal(key: sessionKey, iv: iv, plaintext: z)
            for i in 0..<n {
                var chunk = [UInt8]()
                chunk.reserveCapacity(4 + chunkSize)
                chunk.append(UInt8(seq >> 8)); chunk.append(UInt8(seq & 0xFF))
                chunk.append(UInt8(i)); chunk.append(UInt8(n))
                chunk.append(contentsOf: env[(i * chunkSize)..<min((i + 1) * chunkSize, env.count)])
                queries.append(Wire.buildDnsQuery(qname: qnameFor(chunk), qtype: 10, txid: txid))
            }
            return queries
        }

        for i in 0..<n {
            let piece = Array(z[(i * chunkSize)..<min((i + 1) * chunkSize, z.count)])
            let iv = ivs != nil ? ivs![i % ivs!.count] : arc4random_buf_bytes(12)
            var chunk = [UInt8]()
            chunk.reserveCapacity(4 + 1 + 12 + piece.count + 16)
            chunk.append(UInt8(seq >> 8)); chunk.append(UInt8(seq & 0xFF))
            chunk.append(UInt8(i)); chunk.append(UInt8(n))
            chunk.append(contentsOf: try Crypto.gcmSeal(key: sessionKey, iv: iv, plaintext: piece))
            queries.append(Wire.buildDnsQuery(qname: qnameFor(chunk), qtype: 10, txid: txid))
        }
        return queries
    }

    /// Server-side reassembly used by tests to prove the wire format.
    public static func reassembleUplink(chunks: [[UInt8]], sessionKey: [UInt8]) throws -> [[UInt8]] {
        var parts: [Int: [UInt8]] = [:]
        var total = 0
        for chunk in chunks {
            guard chunk.count > 4, chunk[4] == 0xf1 else { throw EngineError.dns("chunk missing 0xf1") }
            let idx = Int(chunk[2])
            total = Int(chunk[3])
            let iv = Array(chunk[5..<17])
            let ct = Array(chunk[17...])
            parts[idx] = try Crypto.gcmOpen(key: sessionKey, iv: iv, ciphertextAndTag: ct)
        }
        guard parts.count == total else { throw EngineError.dns("missing chunks \(parts.count)/\(total)") }
        var z = [UInt8]()
        for i in 0..<total { z.append(contentsOf: parts[i]!) }
        guard let body = Crypto.zstdDecompress(z) else { throw EngineError.dns("zstd fail") }
        var packets = [[UInt8]]()
        var off = 0
        while off + 2 <= body.count {
            let l = (Int(body[off]) << 8) | Int(body[off + 1])
            off += 2
            guard l > 0, off + l <= body.count else { break }
            packets.append(Array(body[off..<(off + l)]))
            off += l
        }
        return packets
    }

    // MARK: poll

    /// Keepalive poll — NOT the downlink transport (readers are push-based).
    public static func buildPollQuery(pollIdx: Int, rand: Int, assignedIp: String, zone: String, txid: UInt16) -> [UInt8] {
        let qname = "0-poll.39928.\(pollIdx & 0xFFFF).\(rand).s\(assignedIp).\(zone)."
        return Wire.buildDnsQuery(qname: qname, qtype: 10, txid: txid)
    }

    // MARK: downlink

    /// Decodes 0xf1 envelopes from DNS answer rdata into IP packets.
    /// Returns [] for plain "ok" acks. Throws only on decrypt of a valid-looking envelope.
    public static func decodeDownlink(rdata: [UInt8], sessionKey: [UInt8]) throws -> [[UInt8]] {
        guard rdata.count > 13, rdata[0] == 0xf1 else { return [] }
        let iv = Array(rdata[1..<13])
        let ct = Array(rdata[13...])
        let pt: [UInt8]
        do {
            pt = try Crypto.gcmOpen(key: sessionKey, iv: iv, ciphertextAndTag: ct)
        } catch {
            throw EngineError.crypto("downlink decrypt failed")
        }
        guard let body = Crypto.zstdDecompress(pt, maxOutput: EngineConfig.maxDownlinkDecompress) else {
            throw EngineError.dns("downlink zstd failed")
        }
        var packets = [[UInt8]]()
        var off = 0
        while off + 2 <= body.count {
            let l = (Int(body[off]) << 8) | Int(body[off + 1])
            off += 2
            guard l > 0, off + l <= body.count else { break }
            packets.append(Array(body[off..<(off + l)]))
            off += l
        }
        return packets
    }
}

/// Random bytes (SecRandom on Apple platforms).
func arc4random_buf_bytes(_ n: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: n)
    let status = bytes.withUnsafeMutableBufferPointer { ptr in
        SecRandomCopyBytes(kSecRandomDefault, n, ptr.baseAddress!)
    }
    if status != errSecSuccess {
        for i in 0..<n { bytes[i] = UInt8.random(in: 0...255) }
    }
    return bytes
}
