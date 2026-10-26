import 'package:flutter/material.dart';
import '../services/vpn_engine.dart';
import '../theme/bourass_theme.dart';

class HotspotScreen extends StatefulWidget {
  final VpnEngine vpn;
  const HotspotScreen({super.key, required this.vpn});

  @override
  State<HotspotScreen> createState() => _HotspotScreenState();
}

class _HotspotScreenState extends State<HotspotScreen> {
  late bool proxyEnabled;

  @override
  void initState() {
    super.initState();
    proxyEnabled = widget.vpn.hotspotProxy;
  }

  void _save() {
    widget.vpn.setHotspotProxy(proxyEnabled);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BourassTheme.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Hotspot',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              'SAVE',
              style: TextStyle(color: BourassTheme.cyanAccent, fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          const Text(
            'Hotspot SOCKS5 (tous protocoles)',
            style: TextStyle(color: BourassTheme.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Partage le tunnel actif via SOCKS5 sur le réseau du point d’accès.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'SOCKS5 proxy',
                      style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.vpn.hotspotAddress,
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ],
                ),
              ),
              Switch(
                value: proxyEnabled,
                activeColor: BourassTheme.cyanAccent,
                activeTrackColor: BourassTheme.cyanAccent.withOpacity(0.4),
                inactiveThumbColor: Colors.white38,
                inactiveTrackColor: Colors.white12,
                onChanged: (v) => setState(() => proxyEnabled = v),
              ),
            ],
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => widget.vpn.openWirelessSettings(),
            icon: const Icon(Icons.wifi_tethering, color: BourassTheme.cyanAccent, size: 18),
            label: const Text('Ouvrir réglages hotspot', style: TextStyle(color: Colors.white)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF1F2D44)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Activez le point d’accès WiFi vous-même dans les réglages '
            '(Android ne permet plus aux apps de l’activer). Les appareils '
            'connectés utilisent le proxy SOCKS5 de ce téléphone.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
