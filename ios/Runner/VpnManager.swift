import Foundation
import NetworkExtension

/// Owns the NETunnelProviderManager lifecycle: saves the VPN profile with the
/// chosen server passed through `providerConfiguration` (no App Group needed
/// — the system hands the config to the extension), starts/stops the tunnel,
/// and exposes link status.
final class VpnManager {

    static let shared = VpnManager()

    /// Same default lease as the engine (overridable via the in-app token
    /// editor; the engine side has its own copy).
    private static let defaultToken = "6ae92400e940e8720c737c0b2299ffc3b163625c"

    private(set) var status: NEVPNStatus = .invalid
    private(set) var statusDetail = ""
    private(set) var tunnelAddress = ""
    private var manager: NETunnelProviderManager?

    private init() {
        refreshState()
    }

    var sessionToken: String {
        UserDefaults.standard.string(forKey: "session_token") ?? Self.defaultToken
    }

    private var statusObserver: NSObjectProtocol?

    private func observeStatus(of manager: NETunnelProviderManager) {
        if let obs = statusObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
        ) { [weak self] note in
            if let conn = note.object as? NEVPNConnection {
                self?.status = conn.status
            }
        }
    }

    private static func ours(_ m: NETunnelProviderManager) -> Bool {
        (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
            == (Bundle.main.bundleIdentifier ?? "com.fastvpn.inwi") + ".tunnel"
    }

    func refreshState() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { return }
            // Never touch a profile that isn't ours (the user may have other
            // VPN apps installed — managers?.first would hijack them).
            let m = managers?.first(where: Self.ours)
            self.manager = m
            self.status = m?.connection.status ?? .invalid
            self.tunnelAddress = (m?.protocolConfiguration as? NETunnelProviderProtocol)?.serverAddress ?? ""
            if let m = m {
                self.observeStatus(of: m)
            }
        }
    }

    func connect(zone: String, resolver: String, serverIp: String,
                 completion: @escaping (String) -> Void) {
        statusDetail = "Saving VPN configuration …"
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            // reuse OUR profile only; create if missing
            let manager = managers?.first(where: Self.ours) ?? NETunnelProviderManager()
            let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol)
                ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "com.fastvpn.inwi") + ".tunnel"
            proto.serverAddress = zone
            proto.providerConfiguration = [
                "zone": zone,
                "resolver": resolver,
                "serverIp": serverIp,
                "token": self?.sessionToken ?? Self.defaultToken,
            ]
            proto.disconnectOnSleep = false
            manager.protocolConfiguration = proto
            manager.localizedDescription = "BourassVPN"
            manager.isEnabled = true

            manager.saveToPreferences { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.statusDetail = "VPN permission denied (\(error.localizedDescription))"
                    completion("denied")
                    return
                }
                self.statusDetail = "Starting tunnel …"
                // NE quirk: after save, reload and start the loaded manager.
                NETunnelProviderManager.loadAllFromPreferences { managers, _ in
                    guard let loaded = managers?.first(where: Self.ours) else {
                        completion("denied")
                        return
                    }
                    self.manager = loaded
                    self.observeStatus(of: loaded)
                    do {
                        try loaded.connection.startVPNTunnel()
                        completion("ok")
                    } catch {
                        self.statusDetail = "startVPNTunnel failed: \(error.localizedDescription)"
                        completion("denied")
                    }
                }
            }
        }
    }

    func disconnect(completion: @escaping () -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let m = managers?.first(where: Self.ours), m.connection.status != .disconnected,
                  m.connection.status != .invalid else {
                self?.status = .disconnected
                completion()
                return
            }
            m.connection.stopVPNTunnel()
            self?.status = .disconnected
            self?.statusDetail = "Disconnected"
            completion()
        }
    }

    /// Honest link verification (the Dart side polls this): tunnel must be
    /// .connected AND an HTTP probe THROUGH the tunnel must succeed.
    func linkVerified(completion: @escaping (Bool) -> Void) {
        guard status == .connected else {
            statusDetail = status == .connecting ? "Tunnel connecting …" : "Tunnel not connected"
            completion(false)
            return
        }
        StatsStreamHandler.probeLatencyMs { [weak self] ms in
            if ms >= 0 {
                self?.statusDetail = "Tunnel up • probe \(ms) ms"
                completion(true)
            } else {
                self?.statusDetail = "Tunnel up but probe failed"
                completion(false)
            }
        }
    }
}
