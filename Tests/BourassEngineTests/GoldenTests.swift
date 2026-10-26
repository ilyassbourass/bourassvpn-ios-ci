import XCTest
@testable import BourassEngine

/// S1 golden-vector tests: the Swift engine must reproduce the wire bytes
/// proven by the Python oracles (v2_e2e.py / v2_comp_test.py) and the
/// deployed Kotlin engine. Fixtures are deterministic (fixed IVs).
final class GoldenTests: XCTestCase {

    struct Golden: Decodable {
        struct Identity: Decodable {
            let installId, hwid, subId, subKey, sid: String
            let hsKeyV2, hsKeyV1, sessionKeyV2, sessionKeyV1: String
        }
        struct V2: Decodable { let payloadHex, payloadB32, qname, queryHex: String }
        struct V1: Decodable { let qname, queryHex: String }
        struct B32V: Decodable { let `in`, out: String }
        struct Poll: Decodable { let qname, queryHex: String }
        struct Uplink: Decodable {
            let packets: [String]; let seq: Int; let sid, zone, sessionKey: String
            let ivs: [String]; let chunkCount: Int; let chunkHex: [String]
            let qnames: [String]; let queryHex: [String]
        }
        struct Downlink: Decodable {
            let packets: [String]; let sessionKey, rdataHex, responseHex: String
        }
        let identity: Identity
        let v2: V2
        let v1: V1
        let base32: [B32V]
        let poll: Poll
        let uplink: Uplink
        let downlink: Downlink
    }

    static let golden: Golden = {
        let url = Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }()

    func hex(_ s: String) -> [UInt8] { Wire.hexToBytes(s) }
    func eq(_ name: String, _ a: [UInt8], _ b: [UInt8]) {
        XCTAssertEqual(Wire.bytesToHex(a), Wire.bytesToHex(b), name)
    }

    func testIdentityDerivation() {
        let g = Self.golden.identity
        XCTAssertEqual(FastDnsProtocol.installId(sub: g.subId), g.installId)
        XCTAssertEqual(FastDnsProtocol.hwid(sub: g.subId), g.hwid)
        let master = Wire.hexToBytes(EngineConfig.masterKeyHex)
        eq("subKey", FastDnsProtocol.subKey(masterKey: master, sub: g.subId), hex(g.subKey))
        eq("hsKeyV2", FastDnsProtocol.handshakeKey(subKey: hex(g.subKey), keyDev: g.hwid, cert: EngineConfig.certHex), hex(g.hsKeyV2))
        eq("hsKeyV1", FastDnsProtocol.handshakeKey(subKey: hex(g.subKey), keyDev: g.installId, cert: EngineConfig.certHex), hex(g.hsKeyV1))
        eq("sessionKeyV2", FastDnsProtocol.sessionKey(subKey: hex(g.subKey), keyDev: g.hwid, sid: g.sid, cert: EngineConfig.certHex), hex(g.sessionKeyV2))
        eq("sessionKeyV1", FastDnsProtocol.sessionKey(subKey: hex(g.subKey), keyDev: g.installId, sid: g.sid, cert: EngineConfig.certHex), hex(g.sessionKeyV1))
    }

    func testBase32() {
        for v in Self.golden.base32 {
            XCTAssertEqual(Wire.base32Encode(hex(v.in)), v.out, "encode \(v.in)")
            if !v.in.isEmpty {
                XCTAssertEqual(Wire.base32Decode(v.out).map(Wire.bytesToHex), v.in, "decode \(v.out)")
            }
        }
    }

    func testV2HandshakeQuery() {
        let g = Self.golden.v2
        let q = FastDnsProtocol.buildV2HandshakeQuery(
            sub: Self.golden.identity.subId, hwid: Self.golden.identity.hwid,
            cert: EngineConfig.certHex, token: EngineConfig.defaultSessionToken,
            zone: "dns.marocdns.uk", txid: 0x2AB7)
        eq("v2 query", q, hex(g.queryHex))
        XCTAssertEqual(Self.golden.v2.qname, g.qname)
        XCTAssertEqual(Wire.base32Encode(hex(g.payloadHex)), g.payloadB32)
    }

    func testV1HandshakeQuery() {
        let g = Self.golden.v1
        let q = FastDnsProtocol.buildV1HandshakeQuery(
            sub: Self.golden.identity.subId, installId: Self.golden.identity.installId,
            cert: EngineConfig.certHex, zone: "dns.marocdns.uk", txid: 0x2AB7)
        eq("v1 query", q, hex(g.queryHex))
    }

    func testPollQuery() {
        let g = Self.golden.poll
        let q = FastDnsProtocol.buildPollQuery(pollIdx: 7, rand: 424242, assignedIp: "10.8.80.2", zone: "dns.marocdns.uk", txid: 0x0042)
        eq("poll query", q, hex(g.queryHex))
    }

    /// Swift must DECODE uplink chunks produced by the Python oracle
    /// (cross-implementation proof: Python zstd + AESGCM, fixed wire format).
    func testUplinkDecodePythonChunks() throws {
        let g = Self.golden.uplink
        XCTAssertEqual(g.chunkHex.count, g.chunkCount)
        let packets = try FastDnsProtocol.reassembleUplink(
            chunks: g.chunkHex.map(hex), sessionKey: hex(g.sessionKey))
        XCTAssertEqual(packets.count, g.packets.count)
        for (i, p) in packets.enumerated() {
            eq("uplink pkt \(i)", p, hex(g.packets[i]))
        }
        // qname shape: "0-<b32>.s<sid>.<zone>"
        XCTAssertTrue(g.qnames[0].hasPrefix("0-"))
        XCTAssertTrue(g.qnames[0].hasSuffix(".s\(g.sid).\(g.zone)"))
        XCTAssertTrue(g.qnames[0].split(separator: ".").dropLast(g.zone.split(separator: ".").count).last!.hasPrefix("s"), "sid label present before zone")
    }

    /// Swift-built uplink must round-trip through the server-side reassembly,
    /// with wire-legal labels (<=63 octets each, continuation scheme).
    func testUplinkRoundtrip() throws {
        let g = Self.golden.uplink
        let packets = g.packets.map(hex)
        let queries = try FastDnsProtocol.buildUplinkQueries(
            packets: packets, seq: UInt16(g.seq), sid: g.sid, zone: g.zone,
            sessionKey: hex(g.sessionKey), txid: 0x0777)
        XCTAssertGreaterThanOrEqual(queries.count, 3, "incompressible 509 B must span multiple chunks")
        // extract chunk bytes back out of the qnames (join continuation labels)
        let chunks: [[UInt8]] = queries.map { q -> [UInt8] in
            var o = 12
            var labels = [String]()
            while q[o] != 0 {
                let l = Int(q[o]); o += 1
                labels.append(String(decoding: q[o..<(o + l)], as: UTF8.self))
                o += l
            }
            // drop trailing zone labels and the s<sid> label (33 chars, s-prefix)
            let zoneLabelCount = g.zone.split(separator: ".").count
            let dataLabels = labels.dropLast(zoneLabelCount + 1)
            let b32 = dataLabels.map { label -> String in
                guard label.count > 2, let d = label.first, d.isNumber, label[label.index(after: label.startIndex)] == "-" else {
                    return label
                }
                return String(label.dropFirst(2))
            }.joined()
            return Wire.base32Decode(b32)!
        }
        // every label must respect the DNS 63-octet limit
        for q in queries {
            var o = 12
            while q[o] != 0 {
                let l = Int(q[o]); o += 1
                XCTAssertLessThanOrEqual(l, 63, "DNS label exceeds 63 octets")
                o += l
            }
        }
        let decoded = try FastDnsProtocol.reassembleUplink(chunks: chunks, sessionKey: hex(g.sessionKey))
        XCTAssertEqual(decoded.count, packets.count)
        for (i, p) in decoded.enumerated() { eq("roundtrip pkt \(i)", p, packets[i]) }
    }

    func testDownlinkDecode() throws {
        let g = Self.golden.downlink
        let packets = try FastDnsProtocol.decodeDownlink(rdata: hex(g.rdataHex), sessionKey: hex(g.sessionKey))
        XCTAssertEqual(packets.count, g.packets.count)
        for (i, p) in packets.enumerated() { eq("downlink pkt \(i)", p, hex(g.packets[i])) }

        // full DNS response parsing (Go buildResponse shape)
        let answers = Wire.parseAnswers(hex(g.responseHex))
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers[0].type, 10)
        eq("answer rdata", answers[0].rdata, hex(g.rdataHex))
    }

    func testAaaaNodataSuppression() throws {
        // build a synthetic IPv4/UDP DNS AAAA query (checksums not required —
        // the synthesizer only rewrites and recomputes its own)
        var q = [UInt8](repeating: 0, count: 20 + 8 + 12 + 17 + 4)
        q[0] = 0x45; q[2] = UInt8(q.count >> 8); q[3] = UInt8(q.count & 0xFF)
        q[8] = 64; q[9] = 17
        q[12] = 10; q[13] = 8; q[14] = 80; q[15] = 2      // src 10.8.80.2
        q[16] = 10; q[17] = 8; q[18] = 80; q[19] = 1     // dst 10.8.80.1
        let ihl = 20
        q[ihl] = 0; q[ihl + 1] = 53; q[ihl + 2] = 0x53; q[ihl + 3] = 0x35 // sport 53 -> dport 12345? use 40000/53
        q[ihl] = 0x9C; q[ihl + 1] = 0x40                  // sport 40000
        q[ihl + 2] = 0; q[ihl + 3] = 53                   // dport 53
        let dnsOff = ihl + 8
        q[dnsOff + 4] = 0; q[dnsOff + 5] = 1              // QDCOUNT = 1
        q[dnsOff + 12] = 3                                // label len 3
        q[dnsOff + 13] = 119; q[dnsOff + 14] = 119; q[dnsOff + 15] = 119 // "www"
        q[dnsOff + 16] = 3
        q[dnsOff + 17] = 99; q[dnsOff + 18] = 111; q[dnsOff + 19] = 109  // "com"
        let qtypeOff = dnsOff + 21
        q[qtypeOff] = 0; q[qtypeOff + 1] = 28             // AAAA
        q[qtypeOff + 2] = 0; q[qtypeOff + 3] = 1          // IN

        let engine = FastDnsEngine(config: EngineConfig(zone: "u.063990.xyz"))
        guard let resp = engine.synthesizeAaaaNodata(q) else {
            return XCTFail("AAAA query must synthesize a NODATA response")
        }
        // QR=1, ANCOUNT=0, qtype echoed
        let rDns = ihl + 8
        XCTAssertEqual(resp[rDns + 2] & 0x80, 0x80, "QR set")
        XCTAssertEqual(resp[rDns + 6], 0, "ANCOUNT hi")
        XCTAssertEqual(resp[rDns + 7], 0, "ANCOUNT lo")
        XCTAssertEqual(resp[qtypeOff + 1], 28, "qtype echoed")
        // ports swapped: sport 53, dport 40000
        XCTAssertEqual(resp[ihl], 0); XCTAssertEqual(resp[ihl + 1], 53)
        XCTAssertEqual(resp[ihl + 2], 0x9C); XCTAssertEqual(resp[ihl + 3], 0x40)
        // src/dst swapped
        XCTAssertEqual(resp[12], 10); XCTAssertEqual(resp[16], 10); XCTAssertEqual(resp[17], 8)
        // IP checksum valid: folded one's-complement sum over the header
        // (checksum field included) must be 0xFFFF, i.e. its complement is 0
        var s = 0
        for i in stride(from: 0, to: ihl, by: 2) {
            s += (Int(resp[i]) << 8) | Int(resp[i + 1])
        }
        while (s >> 16) != 0 { s = (s & 0xFFFF) + (s >> 16) }
        XCTAssertEqual(~s & 0xFFFF, 0, "IP header checksum valid")
    }

    func testEngineConfigRoster() {
        XCTAssertEqual(EngineConfig.roster.count, 8)
        XCTAssertEqual(EngineConfig.serverMap["dns8.marocdns.uk"], "172.104.140.27", "New CFG dns8 re-point")
        XCTAssertEqual(EngineConfig.serverMap["dns3.marocdns.uk"], "159.223.27.153", "New CFG dns3 re-point")
        XCTAssertNil(EngineConfig.serverMap["dns5.marocdns.uk"], "dns5 dropped")
        let cfg = EngineConfig(zone: "u.063990.xyz")
        XCTAssertEqual(cfg.laneZoneNames.count, 6, "our zone spreads lanes over 6 names")
        XCTAssertTrue(cfg.isOurZone)
        XCTAssertEqual(EngineConfig(zone: "dns.marocdns.uk").laneZoneNames, ["dns.marocdns.uk"])
        XCTAssertEqual(cfg.resolverIps, ["105.73.34.105", "105.73.34.106"])
    }
}
