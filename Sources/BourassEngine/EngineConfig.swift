import Foundation

/// Engine constants — identical to the Android FastDnsEngine + the live
/// Faiz roster read from the phone on 2026-10-25 (New CFG).
public struct EngineConfig {

    // Identity / credentials (Faiz lease, bound to subId; token expiry 2026-11-03)
    public static let masterKeyHex = "@@FAIZ_MASTER@@"
    public static let certHex = "@@FAIZ_CERT@@"
    public static let defaultSessionToken = "@@FAIZ_TOKEN@@"
    public static let subId = "@@FAIZ_SUB@@"

    // Wire parameters (chunkPayload tunable by remote config)
    public static var tunableChunkPayload = 81
    public static var chunkPayload: Int { tunableChunkPayload }  // bytes of envelope per DNS chunk
    public static let maxDownlinkDecompress = 65536

    /// Tunnel roster: zone -> direct server IP (dial fallback when resolvers fail).
    /// Faiz "New CFG" 2026-10-25: dns8 -> fbcdn1 Linode, dns3 -> new DE box,
    /// dns7/dns10 are new; dns5 (BG) and dns6 (ZA) dropped from the roster.
    public static let serverMap: [String: String] = [
        // Ours
        "u.063990.xyz": "158.101.208.5",
        "b.jobixapp.com": "158.101.208.5",
        // Faiz (New CFG, live 2026-10-25)
        "dns.marocdns.uk": "37.221.198.37",
        "dns2.marocdns.uk": "51.170.136.78",
        "dns4.marocdns.uk": "51.178.52.81",
        "dns8.marocdns.uk": "172.104.140.27",
        "dns10.marocdns.uk": "172.239.246.40",
        "dns3.marocdns.uk": "159.223.27.153",
        "dns7.marocdns.uk": "174.138.6.22",
    ]

    public static let primaryResolver = "105.73.34.105"
    public static let secondaryResolver = "105.73.34.106"

    /// Per-zone tunnel descriptor for the UI / roster.
    public struct Tunnel: Identifiable, Hashable {
        public let id: String
        public let name: String
        public let zone: String
        public let publicIp: String
        public let country: String
        public let vip: Bool

        public init(id: String, name: String, zone: String, publicIp: String, country: String, vip: Bool) {
            self.id = id; self.name = name; self.zone = zone; self.publicIp = publicIp
            self.country = country; self.vip = vip
        }
    }

    public static let roster: [Tunnel] = [
        Tunnel(id: "oracle", name: "Bourass • Oracle Amsterdam (Max Fast)", zone: "u.063990.xyz", publicIp: "158.101.208.5", country: "NL", vip: false),
        Tunnel(id: "t1", name: "Tunnel 1 • FastDNS (Germany)", zone: "dns.marocdns.uk", publicIp: "37.221.198.37", country: "DE", vip: false),
        Tunnel(id: "t2", name: "Tunnel 2 • FastDNS (Morocco)", zone: "dns2.marocdns.uk", publicIp: "51.170.136.78", country: "MA", vip: true),
        Tunnel(id: "t3", name: "Tunnel 3 • FastDNS (France)", zone: "dns4.marocdns.uk", publicIp: "51.178.52.81", country: "FR", vip: true),
        Tunnel(id: "t6", name: "Tunnel 6 • FastDNS (fbcdn1 DE)", zone: "dns8.marocdns.uk", publicIp: "172.104.140.27", country: "DE", vip: false),
        Tunnel(id: "t7", name: "Tunnel 7 • FastDNS (dns10 NL)", zone: "dns10.marocdns.uk", publicIp: "172.239.246.40", country: "NL", vip: false),
        Tunnel(id: "t8", name: "Tunnel 8 • FastDNS (dns3 DE)", zone: "dns3.marocdns.uk", publicIp: "159.223.27.153", country: "DE", vip: false),
        Tunnel(id: "t9", name: "Tunnel 9 • FastDNS (dns7 NL)", zone: "dns7.marocdns.uk", publicIp: "174.138.6.22", country: "NL", vip: false),
    ]

    /// Runtime-overridable values (in-app token editor parity with the
    /// Android `fastvpn_engine/session_token` pref).
    public var sessionToken: String = EngineConfig.defaultSessionToken
    public var zone: String = "u.063990.xyz"
    public var resolver: String = ""
    public var serverIp: String = ""
    /// Skip the carrier resolvers entirely (Wi-Fi / CI environments where
    /// 105.73.34.105/106 are unreachable black holes).
    public var directOnly = false
    /// Uplink wire format (see FastDnsProtocol.UplinkFormat).
    public var uplinkFormat: FastDnsProtocol.UplinkFormat = .singleEnvelope  // Freebuff-proven vs Faiz

    public init(zone: String, resolver: String = "", serverIp: String = "",
                sessionToken: String = defaultSessionToken, directOnly: Bool = false,
                uplinkFormat: FastDnsProtocol.UplinkFormat = .perChunk) {
        self.zone = zone
        self.resolver = resolver
        self.serverIp = serverIp
        self.sessionToken = sessionToken
        self.directOnly = directOnly
        self.uplinkFormat = uplinkFormat
    }

    public var masterKey: [UInt8] { Wire.hexToBytes(EngineConfig.masterKeyHex) }
    public var certBytes: [UInt8] { Wire.hexToBytes(EngineConfig.certHex) }

    /// Resolver dial list: primary, configured extras, secondary (deduped).
    public var resolverIps: [String] {
        if directOnly {
            let d = directServerIp
            return d.isEmpty ? [EngineConfig.primaryResolver] : [d]
        }
        var list = [EngineConfig.primaryResolver]
        for p in resolver.split(separator: ",") {
            let clean = p.trimmingCharacters(in: .whitespaces).split(separator: ":").first.map(String.init) ?? ""
            if !clean.isEmpty && !list.contains(clean) { list.append(clean) }
        }
        if !list.contains(EngineConfig.secondaryResolver) { list.append(EngineConfig.secondaryResolver) }
        return list
    }

    /// Lane zone names: our domain delegates u/y/w/x/z/t to the same VPS, so
    /// lanes can spread over names like Faiz does over dns1..dns8. Faiz zones
    /// return the single zone (their NS handles the spread).
    public var laneZoneNames: [String] {
        // The multi-name spread is a carrier-path optimization (phone). When
        // dialing the server directly, the backend parses against the primary
        // zone only — extra lane labels break its uplink parser. One name.
        if directOnly { return [zone] }
        let z = zone.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard z.hasSuffix("063990.xyz") else { return [zone] }
        let base = String(z.dropFirst()) // 063990.xyz
        return ["u", "y", "w", "x", "z", "t"].map { "\($0).\(base)" }
    }

    public var isOurZone: Bool {
        zone.hasSuffix("063990.xyz") || zone.hasSuffix("jobixapp.com")
    }

    public var directServerIp: String {
        EngineConfig.serverMap[zone.trimmingCharacters(in: CharacterSet(charactersIn: "."))] ?? serverIp
    }

    // MARK: runtime tunables (remote-config overridable, no rebuild needed)

    /// Int/Bool/Double overrides applied AFTER init. Recognized keys mirror
    /// the tuning constants the Android engine exposes — see Engine.tunables.
    public mutating func apply(overrides: [String: Any]) {
        for (k, v) in overrides {
            switch k {
            case "laneCount": if let x = toInt(v) { FastDnsEngine.tunableLaneCount = clamp(x, 1, 24) }
            case "stallMs": if let x = toInt(v) { FastDnsEngine.tunableStallMs = Int64(clamp(x, 500, 60000)) }
            case "queryDeadlineMs": if let x = toInt(v) { FastDnsEngine.tunableQueryDeadlineMs = Int64(clamp(x, 1000, 60000)) }
            case "pollTargetInflight": if let x = toInt(v) { FastDnsEngine.tunablePollTarget = clamp(x, 1, 64) }
            case "maxInflightPerLane": if let x = toInt(v) { FastDnsEngine.tunableMaxInflight = clamp(x, 8, 256) }
            case "chunkPayload": if let x = toInt(v) { EngineConfig.tunableChunkPayload = clamp(x, 32, 120) }
            case "uplinkFormat": if let s = v as? String { uplinkFormat = s == "singleEnvelope" ? .singleEnvelope : .perChunk }
            case "directOnly": if let b = v as? Bool { directOnly = b }
            default: break
            }
        }
    }

    private func toInt(_ v: Any) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private func clamp(_ x: Int, _ lo: Int, _ hi: Int) -> Int { min(max(x, lo), hi) }
}
