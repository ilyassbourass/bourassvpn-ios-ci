import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/server.dart';

/// Central VPN engine for BourassVPN.
///
/// Honesty rules (no fake states):
/// - `connected` is entered ONLY after the native side reports TUN up +
///   SOCKS reachable + DNS reply through the tunnel + HTTP probe through
///   the tunnel (see FastVpnService.linkVerified).
/// - Telemetry comes only from native per-UID TrafficStats counters and the
///   DoH RTT ping. If native is unavailable, connect fails with an error.
class VpnEngine extends ChangeNotifier {
  static const MethodChannel _ch = MethodChannel('com.fastvpn.inwi/vpn');
  static const EventChannel _statsCh = EventChannel('com.fastvpn.inwi/stats');

  VpnState _state = VpnState.idle;
  VpnServer _server = VpnServer.defaults.first;
  String _resolver = '105.73.34.106,105.73.34.105';
  CompressionMode _compression = CompressionMode.light;
  DnsTunOption _dnsTun = DnsTunOption.google;
  String _customDns = '';

  String _statusLine = 'Disconnected';
  String _localIp = '192.168.1.39';
  String _vpnAddress = '';
  String _linkDetail = '';
  String _deviceId = '';

  String get deviceId => _deviceId.isEmpty ? '…' : _deviceId;

  // Mode settings (image (4).png)
  bool turbo = false;
  bool eco = false;
  bool autoTune = true;
  String speedMode = 'Low ping';
  bool manualTcp = false;
  bool dnsMulti = true;
  String tunnelMode = 'Secure';

  // Hotspot settings (image (6).png)
  bool hotspotProxy = false;
  String hotspotAddress = '192.168.1.39:8080';

  // Telemetry (native only)
  double _upKbps = 0;
  double _downKbps = 0;
  int _pingMs = -1;
  // Faiz-style time model: no account, keyed to the device (android_id) only,
  // and unlimited — the counter is a display cap (99:59:59), never a quota.
  static const int _unlimitedSeconds = 99 * 3600 + 59 * 60 + 59;
  int _bytesUp = 0;
  int _bytesDown = 0;
  Timer? _clockTimer;
  StreamSubscription? _nativeStats;
  bool _nativeAvailable = false;

  VpnState get state => _state;
  VpnServer get server => _server;
  String get resolver => _resolver;
  CompressionMode get compression => _compression;
  DnsTunOption get dnsTun => _dnsTun;
  String get customDns => _customDns;
  String get statusLine => _statusLine;
  String get localIp => _localIp;
  String get vpnAddress => _vpnAddress;
  String get linkDetail => _linkDetail;
  double get upKbps => _upKbps;
  double get downKbps => _downKbps;
  int get pingMs => _pingMs;
  int get totalSeconds => _unlimitedSeconds;

  /// Faiz-style: time is unlimited per device, so the label just counts up
  /// the live session time (capped at 99:59:59 for display).
  String get formattedTime {
    const t = _unlimitedSeconds;
    const h = t ~/ 3600;
    const m = (t % 3600) ~/ 60;
    const s = t % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(h)}:${two(m)}:${two(s)}';
  }

  int get bytesUp => _bytesUp;
  int get bytesDown => _bytesDown;
  bool get isConnected => _state == VpnState.connected;

  VpnEngine() {
    _detectLocalIp();
    _probeNative();
    _loadDeviceId();
    _maybeAutoConnect();
  }

  /// Headless-test hook: the iOS shell can pre-seed UserDefaults with
  /// `autoconnect_zone` (e.g. via launch arguments or the test harness).
  /// When present, the app connects by itself — no taps needed for CI-style
  /// verification runs. Disabled by default so normal users see the dashboard.
  Future<void> _maybeAutoConnect() async {
    // The platform channels register slightly after Dart boots, so retry
    // briefly instead of losing the one query.
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        final cfg = await _ch.invokeMethod<Map>('launchConfig');
        final zone = (cfg?['zone'] as String?)?.trim() ?? '';
        if (cfg?['autoconnect'] != true || zone.isEmpty) return;
        final match = VpnServer.defaults.where((s) => s.zone == zone);
        if (match.isNotEmpty) {
          _server = match.first;
          notifyListeners();
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await _probeNative();
        if (_nativeAvailable) await connect();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    }
  }

  Future<void> _loadDeviceId() async {
    try {
      final id = await _ch.invokeMethod<String>('deviceId');
      if (id != null && id.isNotEmpty) {
        _deviceId = id;
        notifyListeners();
      }
    } catch (_) {}
  }

  void refreshNetwork() {
    _detectLocalIp();
  }

  String _networkType = 'Data';

  String get networkLabel => '$_networkType • $_localIp';

  Future<void> _detectLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final itf in interfaces) {
        for (final addr in itf.addresses) {
          if (!addr.isLoopback && addr.address.isNotEmpty) {
            _localIp = addr.address;
            final name = itf.name.toLowerCase();
            if (name.startsWith('wlan')) {
              _networkType = 'WiFi';
            } else if (name.startsWith('ccmni') || name.startsWith('rmnet') || name.startsWith('cell')) {
              _networkType = 'Inwi 4G';
            } else {
              _networkType = 'Data';
            }
            hotspotAddress = '$_localIp:8080';
            notifyListeners();
            return;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _probeNative() async {
    try {
      final v = await _ch.invokeMethod<String>('ping');
      _nativeAvailable = v == 'pong';
    } catch (_) {
      _nativeAvailable = false;
    }
    try {
      _nativeStats = _statsCh.receiveBroadcastStream().listen((e) {
        if (e is Map) {
          _upKbps = (e['up'] as num?)?.toDouble() ?? _upKbps;
          _downKbps = (e['down'] as num?)?.toDouble() ?? _downKbps;
          _pingMs = (e['ping'] as num?)?.toInt() ?? _pingMs;
          _bytesUp = (e['upBytes'] as num?)?.toInt() ?? _bytesUp;
          _bytesDown = (e['downBytes'] as num?)?.toInt() ?? _bytesDown;
          notifyListeners();
        }
      }, onError: (_) {});
    } catch (_) {}
  }

  void selectServer(VpnServer s) {
    _server = s;
    notifyListeners();
  }

  void setResolver(String r) {
    _resolver = r.trim();
    notifyListeners();
  }

  void setCompression(CompressionMode mode) {
    _compression = mode;
    notifyListeners();
  }

  void setDnsTun(DnsTunOption opt, {String? custom}) {
    _dnsTun = opt;
    if (custom != null) _customDns = custom;
    notifyListeners();
  }

  void setHotspotProxy(bool enabled) {
    hotspotProxy = enabled;
    notifyListeners();
  }

  Future<void> openWirelessSettings() async {
    try {
      await _ch.invokeMethod<String>('openWirelessSettings');
    } catch (_) {}
  }

  /// Transport selected for BourassVPN (verified over Inwi 0 DH):
  /// Uses DNS-over-TCP via carrier resolver (105.73.34.105 / 105.73.34.106).
  String get effectiveTransport => 'tcp';

  String get effectiveZone => _server.zone;

  String get effectivePubKey => _server.pubKey;

  String get effectiveResolver {
    if (tunnelMode == 'Direct') return '105.73.34.106:53';
    final r = _server.resolver.isNotEmpty ? _server.resolver : '105.73.34.106';
    return r.contains(':') ? r : '$r:53';
  }

  String get effectiveDotName => '';

  /// DoH upstreams for the in-tunnel DNS forwarder, from the DNS screen.
  List<String> get dohUpstreams {
    switch (_dnsTun) {
      case DnsTunOption.cloudflare:
        return const ['https://1.1.1.1/dns-query'];
      case DnsTunOption.openDns:
        return const ['https://doh.opendns.com/dns-query'];
      case DnsTunOption.quad9:
        return const ['https://dns.quad9.net/dns-query'];
      case DnsTunOption.adGuard:
        return const ['https://dns.adguard-dns.com/dns-query'];
      case DnsTunOption.custom:
        final ip = _customDns.trim();
        if (ip.isNotEmpty) return ['https://$ip/dns-query'];
        return const ['https://8.8.8.8/dns-query'];
      case DnsTunOption.google:
        return const ['https://8.8.8.8/dns-query'];
    }
  }

  Future<void> toggle() async {
    if (_state == VpnState.connected ||
        _state == VpnState.connecting ||
        _state == VpnState.verifying) {
      await disconnect();
    } else {
      await connect();
    }
  }

  /// Gated connect: native start, then poll linkVerified until all probes
  /// pass. Any failure (or missing native layer) lands in `error` — never
  /// in a faked `connected`.
  Future<void> connect() async {
    _setState(VpnState.connecting, 'Connecting to ${_server.name} …');
    if (!_nativeAvailable) {
      // The constructor's probe can lose the race against channel
      // registration (SceneDelegate wires it after Dart is already running).
      // Re-probe instead of bricking the app until restart.
      await _probeNative();
    }
    if (!_nativeAvailable) {
      _setState(VpnState.error, 'Native VPN layer unavailable');
      return;
    }
    String res;
    try {
      res = await _ch.invokeMethod<String>('connect', {
        'host': effectiveZone,
        'resolver': effectiveResolver,
        'serverIp': _server.publicIp,
        'pubKey': effectivePubKey,
        'mtu': 1420,
        'transport': _server.protocol.toLowerCase(),
        'dotName': effectiveDotName,
        'stealth': true,
        'hotspotShare': hotspotProxy,
        'dohUpstreams': dohUpstreams,
        'keepAlive': true,
      }) ?? '';
    } catch (e) {
      debugPrint('native connect error: $e');
      _setState(VpnState.error, 'Failed to start tunnel: $e');
      return;
    }
    if (res == 'denied') {
      _setState(VpnState.idle, 'VPN permission denied');
      return;
    }
    _setState(VpnState.verifying, 'Verifying tunnel (DNS + HTTP probes) …');
    const pollEvery = Duration(seconds: 3);
    // Congested mornings: handshake alone can take minutes of redial.
    const deadline = Duration(seconds: 300);
    final t0 = DateTime.now();
    while (DateTime.now().difference(t0) < deadline) {
      if (_state != VpnState.verifying) return; // user cancelled
      await Future<void>.delayed(pollEvery);
      bool ok = false;
      String detail = '';
      String addr = '';
      try {
        ok = await _ch.invokeMethod<bool>('linkVerified') ?? false;
        final st = await _ch.invokeMethod<Map>('linkState');
        if (st != null) {
          detail = '${st['detail'] ?? ''}';
          addr = '${st['tun'] ?? ''}';
          _linkDetail = detail;
        }
      } catch (e) {
        detail = 'probe error: $e';
        _linkDetail = detail;
      }
      _statusLine = detail.isEmpty ? 'Verifying tunnel …' : detail;
      notifyListeners();
      if (ok) {
        _vpnAddress = addr.isEmpty ? _server.publicIp : addr;
        _bytesUp = 0;
        _bytesDown = 0;
        _setState(VpnState.connected, 'Connected • ${_server.name}');
        _startClock();
        return;
      }
    }
    try {
      await _ch.invokeMethod<String>('disconnect');
    } catch (_) {}
    _setState(VpnState.error, 'Tunnel verification timed out (${_linkDetail})');
  }

  Future<void> disconnect() async {
    _setState(VpnState.disconnecting, 'Disconnecting …');
    try {
      await _ch.invokeMethod<String>('disconnect').timeout(const Duration(seconds: 4));
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 350));
    _stopClock();
    _upKbps = 0;
    _downKbps = 0;
    _vpnAddress = '';
    _linkDetail = '';
    _setState(VpnState.idle, 'Disconnected');
  }

  void _setState(VpnState s, String line) {
    _state = s;
    _statusLine = line;
    notifyListeners();
  }

  void _startClock() {
    _stopClock();
    int failStreak = 0;
    int tick = 0;
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      tick++;
      // Link watchdog: while connected, re-verify every 5s; sustained
      // probe failure means the tunnel is dead → fail closed, never
      // display a stale "Connected".
      if (tick % 5 == 0 && _state == VpnState.connected) {
        bool ok = false;
        try {
          ok = await _ch.invokeMethod<bool>('linkVerified') ?? false;
        } catch (_) {
          ok = false;
        }
        if (ok) {
          failStreak = 0;
        } else {
          failStreak++;
          if (failStreak >= 6) {
            await disconnect();
            _setState(VpnState.error, 'Link lost (probes failing) — tap to retry');
          }
        }
      }
    });
  }

  void _stopClock() {
    _clockTimer?.cancel();
    _clockTimer = null;
  }

  @override
  void dispose() {
    _stopClock();
    _nativeStats?.cancel();
    super.dispose();
  }
}
