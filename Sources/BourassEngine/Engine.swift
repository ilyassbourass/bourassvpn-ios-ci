import Foundation

/// FastDnsEngine: Layer-3 IP-over-DNS tunnel engine — faithful Swift port of
/// the deployed Android FastDnsEngine.kt (tuned-oracle build).
///
/// - 24 dual-lane transceivers spread over lane zone names (Faiz parity)
/// - 3-tier uplink QoS (URGENT ctl / HI acks / bulk), mirrored control packets
/// - 2 control-only lanes; batch 8 pkts / 2500 B; zstd + AES-GCM envelopes
/// - poll-as-keepalive with idle gate; per-lane backoff, rotation, blackhole
///   and stall watchdogs; 1-byte split write only on a fresh connection
public protocol TunInterface: AnyObject {
    /// Blocks until at least one IP packet is available.
    func readPackets() throws -> [[UInt8]]
    func writePackets(_ packets: [[UInt8]])
}

/// Injectable sink for engine diagnostics (CLI prints, provider logs to os_log).
public var engineLog: (String) -> Void = { _ in }
func elog(_ s: @autoclosure () -> String) { engineLog(s()) }

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

func sleepMs(_ ms: Int32) { Thread.sleep(forTimeInterval: Double(ms) / 1000.0) }

// MARK: - concurrency helpers

public final class Atomic<T> {
    private var v: T
    private let lock = NSLock()
    public init(_ v: T) { self.v = v }
    public var value: T { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
    public func with<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&v) }
    public func getAndSet(_ new: T) -> T { lock.lock(); defer { lock.unlock() }; let old = v; v = new; return old }
}

/// LinkedBlockingDeque equivalent: size-bounded, head-reinsert on misfit,
/// blocking poll with timeout. Stays FRESH, not deep (Kotlin parity).
final class BlockingDeque<T> {
    private var items: [T] = []
    private let cap: Int
    private let cond = NSCondition()
    init(capacity: Int) { cap = capacity }

    var isEmpty: Bool { cond.lock(); defer { cond.unlock() }; return items.isEmpty }
    var count: Int { cond.lock(); defer { cond.unlock() }; return items.count }

    /// Tail-drop: newest bulk is dropped when full (TCP retransmits recover).
    @discardableResult
    func offer(_ t: T) -> Bool {
        cond.lock(); defer { cond.unlock() }
        guard items.count < cap else { return false }
        items.append(t)
        cond.signal()
        return true
    }

    /// Bump-to-HEAD on size misfit — bumping to tail starves small packets.
    func offerFirst(_ t: T) {
        cond.lock(); defer { cond.unlock() }
        items.insert(t, at: 0)
        cond.signal()
    }

    func poll() -> T? {
        cond.lock(); defer { cond.unlock() }
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }

    func poll(timeoutMs: Int32) -> T? {
        cond.lock(); defer { cond.unlock() }
        if items.isEmpty {
            _ = cond.wait(until: Date().addingTimeInterval(Double(timeoutMs) / 1000.0))
            guard !items.isEmpty else { return nil }
        }
        return items.removeFirst()
    }

    func clear() {
        cond.lock(); defer { cond.unlock() }
        items.removeAll()
    }
}

// MARK: - lane

final class Lane {
    let name: String
    let activeResolver: Atomic<String>
    let zone: Atomic<String>
    let lock = NSLock()
    var sock: TcpSocket?
    var firstQueryWritten = false
    // pending queries: txid -> deadline (fire-and-forget; reader processes downlink)
    var pending: [UInt16: Int64] = [:]
    let delivered = Atomic<Bool>(false)
    let lastDeliveryMs = Atomic<Int64>(0)
    let queriesSinceDelivery = Atomic<Int>(0)
    let failStreak = Atomic<Int>(0)
    let lastPollSentMs = Atomic<Int64>(0)
    let mirrorCooldownMs = Atomic<Int64>(0)
    let backoffMs = Atomic<Int64>(0)
    let nextDialMs = Atomic<Int64>(0)
    let okStreak = Atomic<Int>(0)
    let queriesOnSocket = Atomic<Int>(0)
    let lastRotateMs = Atomic<Int64>(0)
    let socketOpenedMs = Atomic<Int64>(0)

    init(name: String, resolver: String, zone: String) {
        self.name = name
        self.activeResolver = Atomic(resolver)
        self.zone = Atomic(zone)
        self.lastDeliveryMs.value = nowMs()
    }
}

// MARK: - engine

public final class FastDnsEngine {

    // Constants (tuned-Kotlin parity, final Oct 25 config). The *_tunable*
    // mirrors let a remote config override them per-session (no rebuild).
    static let defaultQueryDeadlineMs: Int64 = 5000
    static let defaultMaxInflight = 64
    // Measured p99 on the Inwi path is ~4 s: a 1.4 s watchdog killed healthy
    // lanes mid-flight (281 flows in 30 s, 76% of queries unanswered).
    static let defaultLaneStallMs: Int64 = 6000
    static let idleKeepaliveMs: Int64 = 200
    static let defaultPollTarget = 8
    static let pollMaxPerRound = 8
    static let controlLanes = 2
    static let defaultLaneCount = 12
    // Session self-heal: demand with zero data for this long = the server
    // restarted / session died (every answer is a plain ack) -> re-handshake.
    static let sessionHealMs: Int64 = 6000

    // Remote-config overrides (set via EngineConfig.apply before start)
    static var tunableQueryDeadlineMs: Int64 = defaultQueryDeadlineMs
    static var tunableMaxInflight: Int = defaultMaxInflight
    static var tunableStallMs: Int64 = defaultLaneStallMs
    static var tunablePollTarget: Int = defaultPollTarget
    static var tunableLaneCount: Int = defaultLaneCount

    static var queryDeadlineMs: Int64 { tunableQueryDeadlineMs }
    static var maxInflightPerLane: Int { tunableMaxInflight }
    static var laneStallMs: Int64 { tunableStallMs }
    static var pollTargetInflight: Int { tunablePollTarget }
    static var laneCount: Int { tunableLaneCount }

    public private(set) var config: EngineConfig
    public let totalRxBytes = Atomic<Int64>(0)
    public let totalTxBytes = Atomic<Int64>(0)
    public let uplinkDrops = Atomic<Int64>(0)
    public let queriesSent = Atomic<Int64>(0)
    /// Downlink diagnostics: encrypted envelopes vs plain-text server answers
    /// (e.g. "ok" / "mismatch" / "session_token" — what the server tells us).
    public let answers0xf1 = Atomic<Int>(0)
    public let answersOther = Atomic<Int>(0)
    public let lastOtherAnswer = Atomic<String>("")
    private let lastDataMs = Atomic<Int64>(0)
    private let healing = Atomic<Bool>(false)
    public private(set) var sessionId = ""
    public private(set) var assignedIp = "10.8.80.2"
    var sessionKey: [UInt8]?

    private let running = Atomic<Bool>(false)
    private let ctlQueue = BlockingDeque<[UInt8]>(capacity: 128)
    private let dnsQueue = BlockingDeque<[UInt8]>(capacity: 512)
    private let uplinkQueue = BlockingDeque<[UInt8]>(capacity: 256)
    // control-plane redundancy: DNS/SYN/FIN mirrored onto a second lane
    private let mirrorLock = NSLock()
    private var mirrorItems: [[UInt8]] = []
    private let uplinkSeq = Atomic<Int>(1)
    private let pollSeq = Atomic<Int>(1)
    private let txidGen = Atomic<Int>(0x1000)
    private let lanes: [Lane]

    public init(config: EngineConfig) {
        self.config = config
        let zoneNames = config.laneZoneNames
        var ls: [Lane] = []
        for i in 0..<Self.laneCount {
            let resolver = i % 2 == 0 ? EngineConfig.primaryResolver : EngineConfig.secondaryResolver
            ls.append(Lane(name: "data-\(i)", resolver: resolver, zone: zoneNames[i % zoneNames.count]))
        }
        lanes = ls
    }

    public func handshake() -> Bool {
        if !sessionId.isEmpty { return true }
        return performHandshake()
    }

    @discardableResult
    func performHandshake() -> Bool {
        do {
            let r = try Handshake.perform(config: config, log: { elog($0) })
            sessionId = r.sid
            assignedIp = r.assignedIp
            sessionKey = r.sessionKey
            lastDataMs.value = nowMs()
            return true
        } catch {
            elog("handshake failed: \(error)")
            return false
        }
    }

    @discardableResult
    public func start(tun: TunInterface) -> Bool {
        if running.getAndSet(true) { return true }

        elog("engine start: zone=\(config.zone) resolvers=\(config.resolverIps.joined(separator: ","))")
        if sessionId.isEmpty && !performHandshake() {
            elog("handshake failed")
            stop()
            return false
        }

        let reader = Thread { [weak self] in self?.tunReaderLoop(tun: tun) }
        reader.name = "fastdns-tun-reader"
        reader.start()

        for i in 0..<lanes.count {
            let t = Thread { [weak self] in self?.transceiverLoop(tun: tun, laneIdx: i) }
            t.name = "fastdns-data-\(i)"
            t.start()
            let r = Thread { [weak self] in self?.laneReaderLoop(tun: tun, laneIdx: i) }
            r.name = "fastdns-reader-\(i)"
            r.start()
        }
        elog("engine running: ip=\(assignedIp) sid=\(sessionId) lanes=\(lanes.count)")
        return true
    }

    public func stop() {
        if !running.getAndSet(false) { return }
        ctlQueue.clear(); dnsQueue.clear(); uplinkQueue.clear()
        mirrorLock.lock(); mirrorItems.removeAll(); mirrorLock.unlock()
        invalidateAllSockets()
        elog("engine stopped")
    }

    // MARK: TUN reader — QUIC drop, AAAA NODATA suppression, 3-tier QoS

    private func tunReaderLoop(tun: TunInterface) {
        while running.with({ $0 }) {
            let packets: [[UInt8]]
            do {
                packets = try tun.readPackets()
            } catch {
                if running.with({ $0 }) { elog("tun read: \(error)") }
                return
            }
            for buf in packets {
                handleTunPacket(buf, tun: tun)
            }
        }
    }

    private func handleTunPacket(_ buf: [UInt8], tun: TunInterface) {
        guard buf.count >= 20 else { return }
        let n = buf.count
        let ihl = Int(buf[0] & 0x0F) * 4
        let isUdp = n >= 28 && buf[9] == 17
        var dport = -1
        if isUdp, n >= ihl + 4 {
            dport = (Int(buf[ihl + 2]) << 8) | Int(buf[ihl + 3])
        }

        if dport == 443 {
            return // drop QUIC: force instant HTTP/2 TCP fallback
        }

        // AAAA suppression: answer locally with NODATA (0 ms) — kills the
        // 7-second Happy-Eyeballs IPv6 wait and halves DNS tunnel traffic.
        if dport == 53, n >= ihl + 20, let resp = synthesizeAaaaNodata(buf) {
            tun.writePackets([resp])
            return
        }

        // tier: 0=URGENT (SYN/FIN/RST/DNS/ICMP), 1=HI (ACK/small), 2=bulk
        let isDns = dport == 53
        var tier = 2
        if isDns {
            tier = 0
        } else if n >= 20 && buf[9] == 1 {
            tier = 0 // ICMP shares URGENT: a queued ping looks like a broken tunnel
        } else if isUdp, n >= ihl + 4 {
            let sport = (Int(buf[ihl]) << 8) | Int(buf[ihl + 1])
            if dport == 443 || sport == 443 { tier = 1 }
        } else if n >= 40 && (buf[0] & 0xF0) == 0x40 && buf[9] == 6 {
            if ihl >= 20, n >= ihl + 14 {
                let flags = buf[ihl + 13]
                if flags & 0x07 != 0 { tier = 0 }        // SYN/FIN/RST
                else if n <= ihl + 300 { tier = 1 }      // pure ACK / small
            }
        }

        let pkt = buf
        switch tier {
        case 0:
            if !ctlQueue.offer(pkt) { _ = ctlQueue.poll(); _ = ctlQueue.offer(pkt) }
        case 1:
            if !dnsQueue.offer(pkt) { _ = dnsQueue.poll(); _ = dnsQueue.offer(pkt) }
        default:
            if !uplinkQueue.offer(pkt) { uplinkDrops.value = uplinkDrops.value + 1 }
        }
    }

    /// Local NODATA response for AAAA queries (exact port of the Kotlin synthesizer).
    func synthesizeAaaaNodata(_ buf: [UInt8]) -> [UInt8]? {
        let n = buf.count
        let ihl = Int(buf[0] & 0x0F) * 4
        let dnsOff = ihl + 8
        guard n >= dnsOff + 12 else { return nil }
        let flags = (Int(buf[dnsOff + 2]) << 8) | Int(buf[dnsOff + 3])
        let qd = (Int(buf[dnsOff + 4]) << 8) | Int(buf[dnsOff + 5])
        guard flags & 0x8000 == 0, qd == 1 else { return nil }
        var qoff = dnsOff + 12
        while qoff < n {
            let llen = Int(buf[qoff])
            if llen == 0 { qoff += 1; break }
            if llen & 0xC0 == 0xC0 { qoff += 2; break }
            qoff += 1 + llen
        }
        guard qoff + 4 <= n else { return nil }
        let qtype = (Int(buf[qoff]) << 8) | Int(buf[qoff + 1])
        guard qtype == 28 else { return nil }

        var resp = Array(buf[0..<(qoff + 4)])
        resp[dnsOff + 2] = 0x81 // QR=1, RD=1
        resp[dnsOff + 3] = 0x80 // RA=1, RCODE=0
        for i in 6..<12 { resp[dnsOff + i] = 0 } // AN/NS/AR = 0

        for i in 0..<4 { resp.swapAt(12 + i, 16 + i) } // swap IP
        resp.swapAt(ihl, ihl + 2); resp.swapAt(ihl + 1, ihl + 3) // swap ports

        let udpLen = (qoff + 4) - ihl
        resp[ihl + 4] = UInt8(udpLen >> 8); resp[ihl + 5] = UInt8(udpLen & 0xFF)
        resp[ihl + 6] = 0; resp[ihl + 7] = 0
        let ipLen = qoff + 4
        resp[2] = UInt8(ipLen >> 8); resp[3] = UInt8(ipLen & 0xFF)
        resp[10] = 0; resp[11] = 0
        var csum = 0
        var i = 0
        while i + 1 < ihl {
            csum += (Int(resp[i]) << 8) | Int(resp[i + 1])
            i += 2
        }
        while (csum >> 16) != 0 { csum = (csum & 0xFFFF) + (csum >> 16) }
        let finalCsum = (~csum) & 0xFFFF
        resp[10] = UInt8(finalCsum >> 8); resp[11] = UInt8(finalCsum & 0xFF)
        return resp
    }

    // MARK: sockets

    func getOrCreateSocket(laneIdx: Int) throws -> TcpSocket {
        let lane = lanes[laneIdx]
        lane.lock.lock()
        defer { lane.lock.unlock() }
        if let s = lane.sock, s.isValid { return s }
        if let s = lane.sock { s.close(); lane.sock = nil }

        let waitMs = lane.nextDialMs.value - nowMs()
        if waitMs > 0 { throw EngineError.socket("lane backoff \(waitMs)ms") }
        // fresh socket = fresh chance; do not keep the old penalty
        lane.backoffMs.value = 0
        lane.nextDialMs.value = 0

        let resolver = lane.activeResolver.value
        let fresh: TcpSocket
        do {
            fresh = try TcpSocket.connect(host: resolver, connectTimeoutMs: 5000)
        } catch {
            let alt = resolver == EngineConfig.secondaryResolver ? EngineConfig.primaryResolver : EngineConfig.secondaryResolver
            do {
                elog("lane \(laneIdx) dial to \(resolver) failed (\(error)), trying \(alt)")
                lane.activeResolver.value = alt
                fresh = try TcpSocket.connect(host: alt, connectTimeoutMs: 5000)
            } catch {
                // Wi-Fi / CI environments: both carrier resolvers unreachable —
                // last resort is the zone's server IP directly (the handshake
                // host list already falls back the same way).
                let direct = config.directServerIp
                guard !direct.isEmpty else { throw error }
                elog("lane \(laneIdx) resolvers unreachable, dialing direct \(direct)")
                fresh = try TcpSocket.connect(host: direct, connectTimeoutMs: 5000)
            }
        }
        lane.firstQueryWritten = false
        lane.queriesOnSocket.value = 0
        lane.socketOpenedMs.value = nowMs()
        lane.sock = fresh
        // bounded read timeout so the reader can run the stall watchdog
        fresh.setRecvTimeout(ms: 2000)
        return fresh
    }

    func invalidateSocket(laneIdx: Int, isError: Bool) {
        let lane = lanes[laneIdx]
        var closedExisting = false
        lane.lock.lock()
        if let s = lane.sock {
            s.close()
            lane.sock = nil
            closedExisting = true
        }
        lane.lock.unlock()
        if isError && closedExisting {
            // short ceiling: an 8 s backoff lane starves the tunnel
            let b = lane.backoffMs.with { $0 == 0 ? Int64(250) : min($0 * 2, 1200) }
            lane.backoffMs.value = b
            lane.nextDialMs.value = nowMs() + b + Int64.random(in: 0..<300)
            lane.okStreak.value = 0
            lane.failStreak.value += 1
            if lane.failStreak.value >= 3 {
                let alt = lane.activeResolver.value == EngineConfig.secondaryResolver ? EngineConfig.primaryResolver : EngineConfig.secondaryResolver
                elog("lane \(lane.name): resolver \(lane.activeResolver.value) failed \(lane.failStreak.value)x -> rotate to \(alt)")
                lane.activeResolver.value = alt
                lane.failStreak.value = 0
            }
        }
    }

    func invalidateAllSockets() {
        for i in 0..<lanes.count { invalidateSocket(laneIdx: i, isError: false) }
    }

    // MARK: wire writers

    /// 1-byte split only on the FIRST query of a fresh connection (DPI desync);
    /// steady state is 2-byte length + payload, no sleeps.
    func writeQuerySplit(_ s: TcpSocket, query: [UInt8]) throws {
        try s.send([UInt8(query.count >> 8)])
        sleepMs(2)
        try s.send([UInt8(query.count & 0xFF)] + query)
    }

    func writeQuery(_ lane: Lane, _ s: TcpSocket, _ query: [UInt8]) throws {
        if lane.firstQueryWritten {
            try s.send([UInt8(query.count >> 8), UInt8(query.count & 0xFF)])
            try s.send(query)
        } else {
            try writeQuerySplit(s, query: query)
            lane.firstQueryWritten = true
        }
    }

    // MARK: downlink

    private func processDownlinkBody(tun: TunInterface, laneIdx: Int, respBytes: [UInt8]) {
        guard let key = sessionKey else { return }
        for (_, rdata) in Wire.parseAnswers(respBytes) {
            guard rdata.count > 1 else { continue }
            if rdata[0] == 0xf1 {
                answers0xf1.value += 1
            } else {
                answersOther.value += 1
                if lastOtherAnswer.value.isEmpty {
                    lastOtherAnswer.value = String(decoding: rdata.prefix(24), as: UTF8.self)
                }
                continue
            }
            let packets: [[UInt8]]
            do {
                packets = try FastDnsProtocol.decodeDownlink(rdata: rdata, sessionKey: key)
            } catch {
                elog("lane \(laneIdx) downlink decode: \(error)")
                continue
            }
            if packets.isEmpty { continue }
            tun.writePackets(packets)
            var bytes = 0
            for p in packets { bytes += p.count }
            totalRxBytes.value += Int64(bytes)
            lastDataMs.value = nowMs()
            let lane = lanes[laneIdx]
            lane.delivered.value = true
            lane.queriesSinceDelivery.value = 0
        }
    }

    // MARK: reader loop (push-based downlink)

    private func laneReaderLoop(tun: TunInterface, laneIdx: Int) {
        let lane = lanes[laneIdx]
        while running.with({ $0 }) {
            let sock: TcpSocket
            do {
                sock = try getOrCreateSocket(laneIdx: laneIdx)
            } catch {
                sleepMs(500)
                continue
            }
            do {
                while running.with({ $0 }) {
                    let resp: [UInt8]
                    do {
                        resp = try sock.readFrame()
                    } catch let e as EngineError {
                        // quiet tick or dead flow? in-flight with no delivery
                        // for LANE_STALL_MS = silently dropped -> redial now
                        if case .socket(let msg) = e, msg.contains("timeout") {
                            lane.lock.lock()
                            let pendingCount = lane.pending.count
                            lane.lock.unlock()
                            if pendingCount > 0, nowMs() - lane.lastDeliveryMs.value > Self.laneStallMs {
                                throw EngineError.socket("lane stalled (\(pendingCount) in flight)")
                            }
                            continue
                        }
                        throw e
                    }
                    guard resp.count >= 2 else { continue }
                    let txid = (Int(resp[0]) << 8) | Int(resp[1])
                    lane.lock.lock()
                    lane.pending.removeValue(forKey: UInt16(txid))
                    lane.lock.unlock()
                    // one answer proves the socket works: clear backoff at once
                    lane.failStreak.value = 0
                    lane.okStreak.value += 1
                    lane.backoffMs.value = 0
                    lane.nextDialMs.value = 0
                    lane.lastDeliveryMs.value = nowMs()
                    lane.queriesSinceDelivery.value = 0
                    processDownlinkBody(tun: tun, laneIdx: laneIdx, respBytes: resp)
                }
            } catch {
                if !running.with({ $0 }) { return }
                elog("lane \(laneIdx) reader: \(error)")
                invalidateSocket(laneIdx: laneIdx, isError: true)
                lane.lock.lock()
                lane.pending.removeAll()
                lane.lock.unlock()
                sleepMs(300)
            }
        }
    }

    // MARK: transceiver loop

    private func mirrorQueuePoll() -> [UInt8]? {
        mirrorLock.lock(); defer { mirrorLock.unlock() }
        guard !mirrorItems.isEmpty else { return nil }
        return mirrorItems.removeFirst()
    }

    private var mirrorQueueCount: Int {
        mirrorLock.lock(); defer { mirrorLock.unlock() }
        return mirrorItems.count
    }

    private func mirrorOffer(_ p: [UInt8]) {
        mirrorLock.lock(); defer { mirrorLock.unlock() }
        if mirrorItems.count < 96 { mirrorItems.append(p) }
    }

    private func transceiverLoop(tun: TunInterface, laneIdx: Int) {
        var lastHadDownlink = false
        var idleStreak = 0
        let lane = lanes[laneIdx]

        while running.with({ $0 }) {
            do {
                guard let key = sessionKey else { sleepMs(50); continue }

                let backoffWait = lane.nextDialMs.value - nowMs()
                if backoffWait > 0 { sleepMs(Int32(min(backoffWait, 200))); continue }

                // health first, BEFORE taking a packet off the queue
                lane.lock.lock()
                let pendingCount = lane.pending.count
                lane.lock.unlock()
                if pendingCount > 0, nowMs() - lane.lastDeliveryMs.value > Self.laneStallMs {
                    elog("lane \(laneIdx) stalled -> redial")
                    invalidateSocket(laneIdx: laneIdx, isError: true)
                    lane.lock.lock(); lane.pending.removeAll(); lane.lock.unlock()
                    lane.lastDeliveryMs.value = nowMs()
                    sleepMs(120)
                    continue
                }

                var queriesToSend = [[UInt8]]()

                // take-first order: MIRROR -> URGENT -> HI -> bulk
                var fp: [UInt8]? = nowMs() >= lane.mirrorCooldownMs.value ? mirrorQueuePoll() : nil
                let isMirror = fp != nil
                var ftier = 0
                let isControlLane = laneIdx < Self.controlLanes
                if fp == nil {
                    fp = ctlQueue.poll()
                    if fp == nil, !isControlLane {
                        fp = dnsQueue.poll()
                        ftier = 1
                    }
                    if fp == nil, !isControlLane {
                        fp = uplinkQueue.poll(timeoutMs: 8)
                        ftier = 2
                    }
                }

                func buildBatch(_ first: [UInt8], _ tier: Int) -> [[UInt8]]? {
                    var batchList = [first]
                    var batchTotal = first.count
                    let source: BlockingDeque<[UInt8]> = tier == 0 ? ctlQueue : (tier == 1 ? dnsQueue : uplinkQueue)
                    while batchList.count < 8, batchTotal < 2500 {
                        guard let next = source.poll() else { break }
                        if batchTotal + next.count > 2500 {
                            source.offerFirst(next)
                            break
                        }
                        batchList.append(next)
                        batchTotal += next.count
                    }
                    let seqVal = UInt16(truncatingIfNeeded: uplinkSeq.with { $0 += 1; return $0 })
                    do {
                        let qs = try FastDnsProtocol.buildUplinkQueries(
                            packets: batchList, seq: seqVal, sid: sessionId,
                            zone: lane.zone.value, sessionKey: key, txid: 0,
                            format: config.uplinkFormat)
                        totalTxBytes.value += Int64(batchTotal)
                        return qs
                    } catch {
                        elog("uplink build: \(error)")
                        return nil
                    }
                }

                if let first = fp {
                    idleStreak = 0
                    if let qs = buildBatch(first, ftier) { queriesToSend.append(contentsOf: qs) }
                    // mirror the control packet for a second lane (bounded)
                    if ftier == 0, !isMirror, mirrorQueueCount < 96 {
                        mirrorOffer(first)
                        lane.mirrorCooldownMs.value = nowMs() + 40
                    }
                    var extra = 0
                    while extra < 2, running.with({ $0 }) {
                        var np: [UInt8]?
                        var ntier = 0
                        if let uc = ctlQueue.poll() { np = uc; ntier = 0 }
                        else if isControlLane { break }
                        else if let hc = dnsQueue.poll() { np = hc; ntier = 1 }
                        else if let ub = uplinkQueue.poll() { np = ub; ntier = 2 }
                        else { break }
                        guard let p = np else { break }
                        if let qs = buildBatch(p, ntier) { queriesToSend.append(contentsOf: qs) } else { break }
                        extra += 1
                    }
                }

                // top the poll pipeline up (downlink is fetched by polls)
                let now = nowMs()
                let idleNow = now - lane.lastDeliveryMs.value > 600
                var pollNeed = max(0, min(Self.pollTargetInflight - pendingCountNow(lane), Self.pollMaxPerRound))
                if idleNow {
                    pollNeed = (pendingCountNow(lane) == 0 && now - lane.lastPollSentMs.value >= Self.idleKeepaliveMs) ? 1 : 0
                    if pollNeed > 0 { lane.lastPollSentMs.value = now }
                }
                for _ in 0..<pollNeed {
                    let txid = UInt16.random(in: 0...0xFFFF)
                    let rand = Int.random(in: 0..<1000000)
                    let idx = pollSeq.with { (v: inout Int) -> Int in v += 1; return v } & 0xFFFF
                    queriesToSend.append(FastDnsProtocol.buildPollQuery(
                        pollIdx: idx, rand: rand, assignedIp: assignedIp,
                        zone: lane.zone.value, txid: txid))
                }
                if queriesToSend.isEmpty {
                    if !lastHadDownlink { idleStreak += 1 } else { idleStreak = 0 }
                    if isControlLane { sleepMs(4) }
                }

                // sweep expired in-flight queries
                lane.lock.lock()
                if !lane.pending.isEmpty {
                    let now = nowMs()
                    lane.pending = lane.pending.filter { $0.value > now }
                }
                let inflight = lane.pending.count
                lane.lock.unlock()

                // backpressure: skip the round, never sleep-block the writer
                if inflight >= Self.maxInflightPerLane { continue }

                let sock: TcpSocket
                do {
                    sock = try getOrCreateSocket(laneIdx: laneIdx)
                } catch {
                    sleepMs(500)
                    continue
                }

                // stamp unique txids so responses match out of order
                var stamped = [(UInt16, [UInt8])]()
                for q in queriesToSend where q.count >= 2 {
                    var qq = q
                    let id = UInt16(truncatingIfNeeded: txidGen.with { $0 += 1; return $0 })
                    qq[0] = UInt8(id >> 8); qq[1] = UInt8(id & 0xFF)
                    stamped.append((id, qq))
                }
                let sentAt = nowMs()
                lane.lock.lock()
                for (id, _) in stamped { lane.pending[id] = sentAt + Self.queryDeadlineMs }
                lane.lock.unlock()

                var writeOk = true
                do {
                    for (_, q) in stamped { try writeQuery(lane, sock, q) }
                } catch {
                    elog("lane \(laneIdx) write: \(error)")
                    invalidateSocket(laneIdx: laneIdx, isError: true)
                    writeOk = false
                }
                if !writeOk {
                    lane.lock.lock()
                    for (id, _) in stamped { lane.pending.removeValue(forKey: id) }
                    lane.lock.unlock()
                    sleepMs(300)
                    continue
                }

                queriesSent.value += Int64(stamped.count)
                lane.queriesSinceDelivery.value += stamped.count
                lane.queriesOnSocket.value += stamped.count

                // Session self-heal (Kotlin laneWatchdog parity): real demand +
                // no data answered for 6 s means the session died server-side
                // (server restart wipes sessions; every answer becomes a plain
                // ack). Re-handshake and recycle — the tunnel recovers itself.
                let demand = !ctlQueue.isEmpty || !dnsQueue.isEmpty || !uplinkQueue.isEmpty || inflight >= 3
                if demand, lane.queriesSinceDelivery.value > 40,
                   nowMs() - lastDataMs.value > Self.sessionHealMs,
                   !healing.value {
                    healing.value = true
                    elog("session appears dead (no data for \(Self.sessionHealMs) ms) — re-handshaking")
                    sessionId = ""
                    _ = performHandshake()
                    invalidateAllSockets()
                    for l in lanes {
                        l.queriesSinceDelivery.value = 0
                        l.lastDeliveryMs.value = nowMs()
                    }
                    lastDataMs.value = nowMs()
                    healing.value = false
                    continue
                }

                // blackhole recovery: fresh TCP restores policed flows fast
                let hasDemand = !ctlQueue.isEmpty || !dnsQueue.isEmpty || !uplinkQueue.isEmpty || inflight >= 3
                if hasDemand, lane.queriesSinceDelivery.value > 40,
                   nowMs() - lane.lastDeliveryMs.value > 12000 {
                    elog("lane \(laneIdx) blackhole suspected; redialing")
                    invalidateSocket(laneIdx: laneIdx, isError: true)
                    lane.queriesSinceDelivery.value = 0
                    lane.lastDeliveryMs.value = nowMs()
                    sleepMs(500)
                    continue
                }

                lastHadDownlink = lane.delivered.with { let v = $0; $0 = false; return v }
            } catch {
                if running.with({ $0 }) {
                    elog("lane \(laneIdx) error: \(error)")
                    invalidateSocket(laneIdx: laneIdx, isError: true)
                    sleepMs(150)
                }
            }
        }
    }

    private func pendingCountNow(_ lane: Lane) -> Int {
        lane.lock.lock(); defer { lane.lock.unlock() }
        return lane.pending.count
    }
}
