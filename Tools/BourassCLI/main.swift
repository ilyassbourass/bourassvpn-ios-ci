import Foundation
import BourassEngine

// BourassCLI — validation harness for the S2/S3 ladder stages.
//
//   bourasscli handshake --zone u.063990.xyz [--resolver ip[,ip]] [--token TOK]
//   bourasscli transfer --zone u.063990.xyz [--seconds 30] [--rate 40] [--pktsize 64]
//
// "transfer" runs the FULL engine against the real server: synthetic ICMP
// echo requests ride the tunnel, the server forwards them to the internet,
// and real replies must come back downlink. Exit 0 only on pass criteria.

struct Args {
    var mode = "transfer"
    var zone = "u.063990.xyz"
    var resolver = ""
    var token = EngineConfig.defaultSessionToken
    var seconds = 20
    var rate = 40.0        // synthetic packets per second
    var pktSize = 64
    var direct = false     // skip carrier resolvers (Wi-Fi / CI)
    var uplinkB = false    // single-envelope uplink format (Freebuff-proven vs Faiz)

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            let next = i + 1 < argv.count ? argv[i + 1] : ""
            switch a {
            case "handshake": mode = "handshake"
            case "transfer": mode = "transfer"
            case "--zone": zone = next; i += 1
            case "--resolver": resolver = next; i += 1
            case "--token": token = next; i += 1
            case "--seconds": seconds = Int(next) ?? 20; i += 1
            case "--rate": rate = Double(next) ?? 40; i += 1
            case "--pktsize": pktSize = Int(next) ?? 64; i += 1
            case "--direct": direct = true
            case "--uplink-b": uplinkB = true
            default: break
            }
            i += 1
        }
    }
}

// MARK: synthetic packets (checksum-correct, like the Python oracles)

func checksum(_ data: [UInt8]) -> UInt16 {
    var b = data
    if b.count % 2 != 0 { b.append(0) }
    var s = 0
    var i = 0
    while i < b.count {
        s += (Int(b[i]) << 8) | Int(b[i + 1])
        i += 2
    }
    while (s >> 16) != 0 { s = (s & 0xFFFF) + (s >> 16) }
    return UInt16(~s & 0xFFFF)
}

func ipBytes(_ s: String) -> [UInt8] {
    s.split(separator: ".").compactMap { UInt8($0) }
}

/// IPv4 ICMP echo request, checksummed — the server MASQUERADEs it and the
/// real echo reply comes back downlink.
func icmpEcho(src: String, dst: String, ident: UInt16, seq: UInt16, total: Int) -> [UInt8] {
    let payloadLen = max(0, total - 28)
    var icmp = [UInt8](repeating: 0, count: 8 + payloadLen)
    icmp[0] = 8 // echo request
    icmp[4] = UInt8(ident >> 8); icmp[5] = UInt8(ident & 0xFF)
    icmp[6] = UInt8(seq >> 8); icmp[7] = UInt8(seq & 0xFF)
    for i in 8..<(8 + payloadLen) { icmp[i] = UInt8(truncatingIfNeeded: i) }
    let c = checksum(icmp)
    icmp[2] = UInt8(c >> 8); icmp[3] = UInt8(c & 0xFF)

    var pkt = [UInt8](repeating: 0, count: 20 + icmp.count)
    pkt[0] = 0x45
    let totalLen = 20 + icmp.count
    pkt[2] = UInt8(totalLen >> 8); pkt[3] = UInt8(totalLen & 0xFF)
    pkt[4] = UInt8((ident >> 8) & 0xFF); pkt[5] = UInt8(ident & 0xFF) // ipid
    pkt[8] = 64 // TTL
    pkt[9] = 1  // ICMP
    let sip = ipBytes(src), dip = ipBytes(dst)
    for i in 0..<4 { pkt[12 + i] = sip[i]; pkt[16 + i] = dip[i] }
    let ipc = checksum(Array(pkt[0..<20]))
    pkt[10] = UInt8(ipc >> 8); pkt[11] = UInt8(ipc & 0xFF)
    for (i, b) in icmp.enumerated() { pkt[20 + i] = b }
    return pkt
}

// MARK: synthetic TUN

final class SyntheticTun: TunInterface {
    private let cond = NSCondition()
    private var pending: [[UInt8]] = []
    private let lock = NSLock()
    private(set) var rxPackets = 0
    private(set) var rxBytes = 0
    var onRx: (([UInt8]) -> Void)?

    func offer(_ packets: [[UInt8]]) {
        cond.lock()
        pending.append(contentsOf: packets)
        cond.signal()
        cond.unlock()
    }

    func readPackets() throws -> [[UInt8]] {
        cond.lock()
        if pending.isEmpty {
            _ = cond.wait(until: Date().addingTimeInterval(0.5))
        }
        let out = pending
        pending.removeAll()
        cond.unlock()
        return out
    }

    func writePackets(_ packets: [[UInt8]]) {
        lock.lock()
        rxPackets += packets.count
        rxBytes += packets.reduce(0) { $0 + $1.count }
        lock.unlock()
        for p in packets { onRx?(p) }
    }
}

// MARK: main

let args = Args(Array(CommandLine.arguments.dropFirst()))
engineLog = { print("[engine] \(Date()) \($0)") }

let config = EngineConfig(zone: args.zone, resolver: args.resolver, sessionToken: args.token, directOnly: args.direct, uplinkFormat: args.uplinkB ? .singleEnvelope : .perChunk)
print("== BourassCLI mode=\(args.mode) zone=\(args.zone) resolvers=\(config.resolverIps.joined(separator: ","))")

let t0 = Date()

// Stage: handshake (always)
let engine = FastDnsEngine(config: config)
guard engine.handshake() else {
    print("FAIL: handshake")
    exit(2)
}
let hsMs = Date().timeIntervalSince(t0) * 1000
print(String(format: "handshake ok in %.0f ms — sid=%@ ip=%@", hsMs, engine.sessionId, engine.assignedIp))

if args.mode == "handshake" {
    print("PASS: handshake-only mode")
    exit(0)
}

// Stage: full transfer through the real engine
let tun = SyntheticTun()
engine.start(tun: tun)

// Packet generator on its own thread (a main-RunLoop Timer would never fire
// while the main thread sleeps in the stats loop below).
let endDate = Date().addingTimeInterval(Double(args.seconds))
let sentCount = BourassEngine.Atomic<Int>(0)
let genThread = Thread {
    var seq: UInt16 = 0
    let interval = 1.0 / max(args.rate, 0.1)
    var next = Date()
    while Date() < endDate {
        seq &+= 1
        let pkt = icmpEcho(src: engine.assignedIp, dst: "1.1.1.1", ident: 0xB0B5, seq: seq, total: args.pktSize)
        tun.offer([pkt])
        sentCount.value += 1
        next = next.addingTimeInterval(interval)
        let wait = next.timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }
}
genThread.name = "synthetic-gen"
genThread.start()

var lastRx = 0
var lastTx: Int64 = 0
var lastQ: Int64 = 0
for sec in 1...args.seconds {
    Thread.sleep(forTimeInterval: 1.0)
    let rx = tun.rxPackets
    let tx = engine.totalTxBytes.value
    let q = engine.queriesSent.value
    print(String(format: "t=%02ds rx=%d pkts (%+d) tx=%lld B (%+lld) queries=%lld (%+lld)",
                 sec, rx, rx - lastRx, tx, tx - lastTx, q, q - lastQ))
    lastRx = rx; lastTx = tx; lastQ = q
}
engine.stop()

let rxTotal = tun.rxPackets
let sentPackets = sentCount.value
print(String(format: "done: sent %d synthetic pkts, got %d replies (%.0f%%), rx=%d B tx=%lld B queries=%lld",
             sentPackets, rxTotal, sentPackets > 0 ? Double(rxTotal) / Double(sentPackets) * 100 : 0,
             tun.rxBytes, engine.totalTxBytes.value, engine.queriesSent.value))
print("answers: encrypted0xf1=\(engine.answers0xf1.value) other=\(engine.answersOther.value) sample='\(engine.lastOtherAnswer.value)'")

let pass = rxTotal >= max(3, sentPackets / 4) // >=25% of echoes come back
print(pass ? "PASS: transfer" : "FAIL: transfer")
exit(pass ? 0 : 3)
