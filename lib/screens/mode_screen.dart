import 'package:flutter/material.dart';
import '../models/server.dart';
import '../services/vpn_engine.dart';
import '../theme/bourass_theme.dart';

class ModeScreen extends StatefulWidget {
  final VpnEngine vpn;
  const ModeScreen({super.key, required this.vpn});

  @override
  State<ModeScreen> createState() => _ModeScreenState();
}

class _ModeScreenState extends State<ModeScreen> {
  late bool turbo;
  late bool eco;
  late bool autoTune;
  late String speedMode;
  late bool manualTcp;
  late bool dnsMulti;
  late CompressionMode compression;
  late String tunnelMode;

  @override
  void initState() {
    super.initState();
    turbo = widget.vpn.turbo;
    eco = widget.vpn.eco;
    autoTune = widget.vpn.autoTune;
    speedMode = widget.vpn.speedMode;
    manualTcp = widget.vpn.manualTcp;
    dnsMulti = widget.vpn.dnsMulti;
    compression = widget.vpn.compression;
    tunnelMode = widget.vpn.tunnelMode;
  }

  void _save() {
    widget.vpn.turbo = turbo;
    widget.vpn.eco = eco;
    widget.vpn.autoTune = autoTune;
    widget.vpn.speedMode = speedMode;
    widget.vpn.manualTcp = manualTcp;
    widget.vpn.dnsMulti = dnsMulti;
    widget.vpn.setCompression(compression);
    widget.vpn.tunnelMode = tunnelMode;
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
          'Mode',
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
          // Section 1: Performance (FastDNS only)
          const Text(
            'Performance (FastDNS only)',
            style: TextStyle(color: BourassTheme.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Préréglages du tunnel FastDNS.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 12),
          _SwitchTile(
            title: 'Turbo',
            subtitle: 'Max throughput • disables auto-tune',
            value: turbo,
            onChanged: (v) => setState(() => turbo = v),
          ),
          _SwitchTile(
            title: 'Éco',
            subtitle: 'Less battery / heat',
            value: eco,
            onChanged: (v) => setState(() => eco = v),
          ),
          _SwitchTile(
            title: 'Auto-tune',
            subtitle: null,
            value: autoTune,
            onChanged: (v) => setState(() => autoTune = v),
          ),
          // Speed mode
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Speed mode', style: TextStyle(color: Colors.white70, fontSize: 14)),
                      SizedBox(height: 2),
                      Text('Low ping', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                ),
                DropdownButton<String>(
                  value: speedMode,
                  dropdownColor: const Color(0xFF141C2B),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  underline: const SizedBox(),
                  items: ['Low ping', 'Balanced', 'Maximum speed'].map((m) {
                    return DropdownMenuItem(value: m, child: Text(m));
                  }).toList(),
                  onChanged: (v) => setState(() => speedMode = v ?? speedMode),
                ),
              ],
            ),
          ),
          _SwitchTile(
            title: 'Manual TCP sessions',
            subtitle: null,
            value: manualTcp,
            onChanged: (v) => setState(() => manualTcp = v),
          ),
          _SwitchTile(
            title: 'DNS multi (6 sockets)',
            subtitle: null,
            value: dnsMulti,
            onChanged: (v) => setState(() => dnsMulti = v),
          ),
          const SizedBox(height: 18),
          // Section 2: Compression (FastDNS only)
          const Text(
            'Compression (FastDNS only)',
            style: TextStyle(color: BourassTheme.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0C121E),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: Row(
              children: CompressionMode.values.map((mode) {
                final isSelected = mode == compression;
                return Expanded(
                  child: InkWell(
                    onTap: () => setState(() => compression = mode),
                    borderRadius: BorderRadius.circular(9),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0xFF1A334B) : Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                        border: isSelected ? Border.all(color: BourassTheme.cyanAccent.withOpacity(0.5)) : null,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        isSelected ? '✓ ${mode.label}' : mode.label,
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white60,
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            compression.hint,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 22),
          // Section 3: transport
          const Text(
            'Transport',
            style: TextStyle(color: BourassTheme.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Secure = tiny-frame (réseaux contraints) • Compatibility = FastDNS classique via Inwi • Direct = FastDNS via Inwi bis.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                      Text('Tunnel mode', style: TextStyle(color: Colors.white, fontSize: 14)),
                      SizedBox(height: 2),
                      Text('Applies on next connect', style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ],
                ),
              ),
              DropdownButton<String>(
                value: tunnelMode,
                dropdownColor: const Color(0xFF141C2B),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                underline: Container(height: 1, color: Colors.white30),
                items: ['Secure', 'Compatibility', 'Direct'].map((m) {
                  return DropdownMenuItem(value: m, child: Text(m));
                }).toList(),
                onChanged: (v) => setState(() => tunnelMode = v ?? tunnelMode),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 14)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ],
            ),
          ),
          Switch(
            value: value,
            activeColor: BourassTheme.cyanAccent,
            activeTrackColor: BourassTheme.cyanAccent.withOpacity(0.4),
            inactiveThumbColor: Colors.white38,
            inactiveTrackColor: Colors.white12,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
