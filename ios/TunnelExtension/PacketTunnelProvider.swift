import Foundation
import NetworkExtension
import BourassEngine
import os

/// The Packet Tunnel Provider: bridges NEPacketTunnelProvider's packetFlow to
/// the ported FastDnsEngine. Config arrives via protocolConfiguration.
/// providerConfiguration (set by the app) — no App Group required.
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private var engine: FastDnsEngine?
    private var flowTun: FlowTun?

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        let cfg = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration as? [String: Any]
        let zone = cfg?["zone"] as? String ?? "u.063990.xyz"
        let resolver = cfg?["resolver"] as? String ?? ""
        let serverIp = cfg?["serverIp"] as? String ?? ""
        let token = cfg?["token"] as? String ?? EngineConfig.defaultSessionToken

        let logger = Logger(subsystem: "com.fastvpn.inwi.tunnel", category: "engine")
        let logURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("engine.log")
        try? Data().write(to: logURL)  // truncate per session
        engineLog = { msg in
            NSLog("[BourassEngine] %@", msg)
            let line = "\(Date()) \(msg)\n"
            if let data = line.data(using: .utf8) {
                if let fh = try? FileHandle(forWritingTo: logURL) {
                    fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                } else {
                    try? data.write(to: logURL)
                }
            }
        }

        var config = EngineConfig(zone: zone, resolver: resolver,
                                  serverIp: serverIp, sessionToken: token)
        if let tunables = cfg?["tunables"] as? [String: Any] {
            config.apply(overrides: tunables)
        }
        let engine = FastDnsEngine(config: config)
        self.engine = engine

        // Handshake first — the provider's own sockets bypass the tunnel, so
        // the carrier resolvers are reachable before routes exist.
        guard await withCheckedContinuation({ cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: engine.handshake())
            }
        }) else {
            throw ProviderError.handshakeFailed
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverIp.isEmpty ? "158.101.208.5" : serverIp)
        let ipv4 = NEIPv4Settings(addresses: [engine.assignedIp],
                                  subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [
            NEIPv4Route.default(), // 0.0.0.0/0 (system splits it)
        ]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        settings.mtu = 1420

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }

        let flowTun = FlowTun(flow: packetFlow)
        self.flowTun = flowTun
        flowTun.start()
        guard engine.start(tun: flowTun) else {
            throw ProviderError.engineFailed
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        engine?.stop()
        flowTun = nil
        completionHandler()
    }

    enum ProviderError: Error {
        case handshakeFailed
        case engineFailed
    }
}

/// Adapts NEPacketTunnelFlow's callback API to the engine's blocking TunInterface.
final class FlowTun: TunInterface {

    private let flow: NEPacketTunnelFlow
    private let cond = NSCondition()
    private var buffered: [[Data]] = []
    private(set) var running = false

    init(flow: NEPacketTunnelFlow) {
        self.flow = flow
    }

    func start() {
        running = true
        readLoop()
    }

    private func readLoop() {
        guard running else { return }
        flow.readPackets { [weak self] (packets: [Data], _: [NSNumber]) in
            guard let self = self else { return }
            if !packets.isEmpty {
                self.cond.lock()
                self.buffered.append(packets)
                self.cond.signal()
                self.cond.unlock()
            }
            self.readLoop()
        }
    }

    func readPackets() throws -> [[UInt8]] {
        cond.lock()
        if buffered.isEmpty {
            _ = cond.wait(until: Date().addingTimeInterval(0.5))
        }
        let out = buffered
        buffered.removeAll()
        cond.unlock()
        return out.flatMap { $0.map { Array($0) } }
    }

    func writePackets(_ packets: [[UInt8]]) {
        let datas = packets.map { Data($0) }
        let protocols = [NSNumber](repeating: NSNumber(value: AF_INET), count: datas.count)
        flow.writePackets(datas, withProtocols: protocols)
    }
}
