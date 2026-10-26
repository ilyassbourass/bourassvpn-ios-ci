import Foundation

/// Handshake orchestration. v2 ("0h.") for Faiz zones, v1 long form for our
/// Oracle zone (which only speaks UDPA v1 — trying v2 there just burns a
/// TCP timeout per host).
public struct SessionResult {
    public let sid: String
    public let assignedIp: String
    public let sessionKey: [UInt8]
    public let variant: String
}

public enum Handshake {

    /// TCP first (split-write on the first query), UDP fallback.
    static func sendHandshake(query: [UInt8], hosts: [String], log: (String) -> Void) -> [UInt8]? {
        for host in hosts {
            do {
                let s = try TcpSocket.connect(host: host, connectTimeoutMs: 4000)
                defer { s.close() }
                s.setRecvTimeout(ms: 10000)
                // 1-byte split write (DPI desync, first query on a fresh connection)
                try s.send([UInt8(query.count >> 8)])
                Thread.sleep(forTimeInterval: 0.002)
                try s.send([UInt8(query.count & 0xFF)] + query)
                let resp = try s.readFrame()
                if let ans = Wire.parseFirstAnswer(resp), !ans.isEmpty {
                    log("handshake answer \(ans.count) B from \(host):53")
                    return ans
                }
                log("handshake from \(host):53 empty answer (\(resp.count) B)")
            } catch {
                log("handshake TCP to \(host):53 failed: \(error)")
            }
        }
        for host in hosts {
            do {
                let resp = try UdpDns.query(host: host, query: query)
                if let ans = Wire.parseFirstAnswer(resp), !ans.isEmpty {
                    log("handshake answer \(ans.count) B (UDP) from \(host):53")
                    return ans
                }
            } catch {
                log("handshake UDP to \(host):53 failed: \(error)")
            }
        }
        return nil
    }

    public static func perform(config: EngineConfig, log: (String) -> Void = { _ in }) throws -> SessionResult {
        let sub = EngineConfig.subId
        let installId = FastDnsProtocol.installId(sub: sub)
        let hw = FastDnsProtocol.hwid(sub: sub)
        let subKey = FastDnsProtocol.subKey(masterKey: config.masterKey, sub: sub)

        var hosts = config.resolverIps
        let directIp = config.directServerIp
        if !directIp.isEmpty && !hosts.contains(directIp) { hosts.append(directIp) }

        let txid = UInt16.random(in: 0...0xFFFF)
        let v2Query = FastDnsProtocol.buildV2HandshakeQuery(
            sub: sub, hwid: hw, cert: EngineConfig.certHex, token: config.sessionToken,
            zone: config.zone, txid: txid)
        let v1Query = FastDnsProtocol.buildV1HandshakeQuery(
            sub: sub, installId: installId, cert: EngineConfig.certHex,
            zone: config.zone, txid: txid)
        log("handshake v2 qname built (sub=\(sub), hwid=\(hw))")

        let candidates: [(String, [UInt8], String)] = config.isOurZone
            ? [("v1-long", v1Query, installId)]
            : [("v2-0h", v2Query, hw), ("v1-long", v1Query, installId)]

        for (label, query, keyDev) in candidates {
            guard let rdata = sendHandshake(query: query, hosts: hosts, log: log) else { continue }
            guard rdata.count >= 29, rdata[0] == 0xf1 else {
                log("handshake \(label) rejected: \(String(decoding: rdata, as: UTF8.self))")
                continue
            }
            do {
                let hsKey = FastDnsProtocol.handshakeKey(subKey: subKey, keyDev: keyDev, cert: EngineConfig.certHex)
                let iv = Array(rdata[1..<13])
                let ct = Array(rdata[13...])
                let plain = try Crypto.gcmOpen(key: hsKey, iv: iv, ciphertextAndTag: ct)
                guard let obj = try JSONSerialization.jsonObject(with: Data(plain)) as? [String: Any],
                      let sid = obj["sid"] as? String,
                      let ip = obj["ip"] as? String else {
                    log("handshake \(label) answer missing sid/ip")
                    continue
                }
                let sKey = FastDnsProtocol.sessionKey(subKey: subKey, keyDev: keyDev, sid: sid, cert: EngineConfig.certHex)
                log("handshake SUCCESS (\(label)): sid=\(sid) ip=\(ip)")
                return SessionResult(sid: sid, assignedIp: ip, sessionKey: sKey, variant: label)
            } catch {
                log("handshake \(label) answer did not decrypt: \(error)")
            }
        }
        throw EngineError.handshake("all handshake candidates rejected")
    }
}
