import Flutter
import Foundation
import UIKit

/// Implements the `com.fastvpn.inwi/vpn` MethodChannel and the
/// `com.fastvpn.inwi/stats` EventChannel — the same contract the Android
/// FastVpnService exposes to the Dart VpnEngine.
enum VpnBridge {

    static func register(with messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "com.fastvpn.inwi/vpn", binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in handle(call: call, result: result) }
        let stats = FlutterEventChannel(name: "com.fastvpn.inwi/stats", binaryMessenger: messenger)
        stats.setStreamHandler(StatsStreamHandler())
    }

    private static func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "ping":
            result("pong")
        case "deviceId":
            result(deviceId())
        case "connect":
            let args = call.arguments as? [String: Any] ?? [:]
            // resolver arrives as "ip:53" — strip the port like Android does
            let resolverRaw = args["resolver"] as? String ?? ""
            let resolver = resolverRaw.split(separator: ":").first.map(String.init) ?? resolverRaw
            VpnManager.shared.connect(
                zone: args["host"] as? String ?? "u.063990.xyz",
                resolver: resolver,
                serverIp: args["serverIp"] as? String ?? "") { outcome in
                DispatchQueue.main.async { result(outcome) }
            }
        case "disconnect":
            VpnManager.shared.disconnect {
                DispatchQueue.main.async { result("ok") }
            }
        case "linkVerified":
            VpnManager.shared.linkVerified { ok in
                DispatchQueue.main.async { result(ok) }
            }
        case "linkState":
            result(["detail": VpnManager.shared.statusDetail as Any,
                    "tun": VpnManager.shared.tunnelAddress as Any])
        case "launchConfig":
            // Headless-test hook: `dvt launch <bundle> -autoconnect <zone>`
            result(["autoconnect": UserDefaults.standard.bool(forKey: "autoconnect"),
                    "zone": UserDefaults.standard.string(forKey: "autoconnect_zone") ?? ""])
        case "setSessionToken":
            if let token = (call.arguments as? [String: Any])?["token"] as? String, !token.isEmpty {
                UserDefaults.standard.set(token, forKey: "session_token")
                result("ok")
            } else {
                result(FlutterError(code: "bad_token", message: "empty token", details: nil))
            }
        case "openWirelessSettings":
            DispatchQueue.main.async {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Stable per-install device ID (display only — the tunnel subId is a
    /// credential constant in the engine, not hardware-bound).
    private static func deviceId() -> String {
        let key = "bourass_device_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let id = (UIDevice.current.identifierForVendor?.uuidString
                  ?? UUID().uuidString).replacingOccurrences(of: "-", with: "")
        let short = String(id.prefix(16)).lowercased()
        UserDefaults.standard.set(short, forKey: key)
        return short
    }
}

/// Throughput telemetry sampled from the utun interface counters (no IPC with
/// the extension needed) plus an HTTP probe for ping.
final class StatsStreamHandler: NSObject, FlutterStreamHandler {
    private var timer: Timer?
    private var sink: FlutterEventSink?
    private var lastUp: UInt64 = 0
    private var lastDown: UInt64 = 0
    private var lastPingMs: Int = -1

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        lastUp = 0; lastDown = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        timer?.invalidate()
        timer = nil
        sink = nil
        return nil
    }

    private func tick() {
        guard let sink = sink else { return }
        let (up, down) = StatsStreamHandler.utunCounters()
        let dUp = up > lastUp ? up - lastUp : 0
        let dDown = down > lastDown ? down - lastDown : 0
        lastUp = up; lastDown = down
        // FlutterEventChannel sinks must be invoked on the platform thread.
        func emit(_ dict: [String: Any]) {
            DispatchQueue.main.async { sink(dict) }
        }
        if VpnManager.shared.status == .connected {
            Self.probeLatencyMs { [weak self] ms in
                guard let self = self else { return }
                self.lastPingMs = ms
                emit([
                    "up": Double(dUp) * 8.0 / 1000.0,
                    "down": Double(dDown) * 8.0 / 1000.0,
                    "ping": self.lastPingMs,
                    "upBytes": Int(up),
                    "downBytes": Int(down),
                ])
            }
        } else {
            emit(["up": 0.0, "down": 0.0, "ping": -1,
                  "upBytes": Int(up), "downBytes": Int(down)])
        }
    }

    /// Summed utun interface counters (in = downlink, out = uplink).
    static func utunCounters() -> (up: UInt64, down: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        var up: UInt64 = 0
        var down: UInt64 = 0
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("utun"),
                  let data = p.pointee.ifa_data,
                  p.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let stats = data.assumingMemoryBound(to: if_data64.self).pointee
            up += UInt64(stats.ifi_obytes)
            down += UInt64(stats.ifi_ibytes)
        }
        return (up, down)
    }

    /// HTTP probe THROUGH the tunnel (app traffic rides the VPN) — also used
    /// by linkVerified.
    static func probeLatencyMs(completion: @escaping (Int) -> Void) {
        let t0 = Date()
        var req = URLRequest(url: URL(string: "http://1.1.1.1/")!)
        req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { _, _, error in
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            completion(error == nil ? ms : -1)
        }.resume()
    }
}
