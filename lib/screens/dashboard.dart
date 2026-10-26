import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/server.dart';
import '../services/vpn_engine.dart';
import '../theme/bourass_theme.dart';
import '../widgets/app_drawer.dart';
import 'tunnel_modal.dart';
import 'resolver_dialog.dart';
import 'mode_screen.dart';

class DashboardScreen extends StatelessWidget {
  final VpnEngine vpn;
  const DashboardScreen({super.key, required this.vpn});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: vpn,
      builder: (context, _) {
        final isConnected = vpn.isConnected;
        final isConnecting = vpn.state == VpnState.connecting || vpn.state == VpnState.verifying;

        return Scaffold(
          backgroundColor: BourassTheme.background,
          drawer: BourassDrawer(vpn: vpn),
          appBar: AppBar(
            backgroundColor: BourassTheme.background,
            elevation: 0,
            leading: Builder(
              builder: (ctx) => IconButton(
                icon: const Icon(Icons.menu, color: BourassTheme.cyanAccent, size: 26),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
            centerTitle: true,
            title: const Text(
              'BourassVPN',
              style: TextStyle(
                color: BourassTheme.cyanAccent,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh, color: BourassTheme.cyanAccent, size: 24),
                onPressed: () {
                  HapticFeedback.lightImpact();
                  vpn.refreshNetwork();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: BourassTheme.cardBg,
                      duration: const Duration(seconds: 1),
                      content: Text(
                        'Actualisé • IP: ${vpn.localIp}',
                        style: const TextStyle(color: BourassTheme.cyanAccent),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  // Hero Circular Power Button (matching image.png)
                  Center(
                    child: GestureDetector(
                      onTap: () async {
                        HapticFeedback.heavyImpact();
                        await vpn.toggle();
                      },
                      child: Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF0F1A2A),
                          boxShadow: [
                            BoxShadow(
                              color: isConnected
                                  ? BourassTheme.greenAccent.withOpacity(0.35)
                                  : isConnecting
                                      ? BourassTheme.amberAccent.withOpacity(0.35)
                                      : BourassTheme.cyanAccent.withOpacity(0.35),
                              blurRadius: 36,
                              spreadRadius: 4,
                            ),
                          ],
                          border: Border.all(
                            color: isConnected
                                ? BourassTheme.greenAccent
                                : isConnecting
                                    ? BourassTheme.amberAccent
                                    : BourassTheme.cyanAccent,
                            width: 3,
                          ),
                        ),
                        child: Center(
                          child: Icon(
                            Icons.power_settings_new_rounded,
                            size: 64,
                            color: isConnected
                                ? BourassTheme.greenAccent
                                : isConnecting
                                    ? BourassTheme.amberAccent
                                    : BourassTheme.cyanAccent,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  // Connection Status
                  Text(
                    isConnected ? 'Connected' : isConnecting ? 'Connecting…' : 'Disconnected',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    vpn.networkLabel,
                    style: const TextStyle(
                      color: BourassTheme.cyanAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Live link stats (real native counters only)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF101726),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFF1B2639)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _StatItem(
                          icon: Icons.arrow_downward_rounded,
                          label: 'DOWN',
                          value: '${vpn.downKbps.toStringAsFixed(1)} kb/s',
                        ),
                        _StatItem(
                          icon: Icons.arrow_upward_rounded,
                          label: 'UP',
                          value: '${vpn.upKbps.toStringAsFixed(1)} kb/s',
                        ),
                        _StatItem(
                          icon: Icons.speed_rounded,
                          label: 'PING',
                          value: vpn.pingMs >= 0 ? '${vpn.pingMs} ms' : '—',
                        ),
                        _StatItem(
                          icon: Icons.data_usage_rounded,
                          label: 'DATA',
                          value: _formatBytes(vpn.bytesDown + vpn.bytesUp),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Faiz-style: time is UNLIMITED per device (android_id),
                  // no account, no quota — the button just shows the info.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'VPN  time  •  UNLIMITED',
                        style: TextStyle(
                          color: BourassTheme.cyanAccent,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () => _showTimeSheet(context, vpn),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: BourassTheme.cyanAccent, width: 1.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text(
                          'Add Time',
                          style: TextStyle(color: BourassTheme.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'ID  ${vpn.deviceId}  •  unlimited for this device',
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Stacked Selection Card 1: TUNNEL
                  _SelectionCard(
                    category: 'TUNNEL',
                    title: '${vpn.server.flag} ${vpn.server.name}',
                    subtitle: vpn.server.protocol,
                    onTap: () => ChooseTunnelModal.show(context, vpn),
                  ),
                  const SizedBox(height: 12),

                  // Stacked Selection Card 2: RESOLVER
                  _SelectionCard(
                    category: 'RESOLVER',
                    title: 'Auto DNS',
                    subtitle: '${vpn.resolver} • 4G fallback',
                    onTap: () => FastDnsResolverDialog.show(context, vpn),
                  ),
                  const SizedBox(height: 12),

                  // Stacked Selection Card 3: COMPRESSION
                  _SelectionCard(
                    category: 'COMPRESSION',
                    title: vpn.compression.label,
                    subtitle: vpn.compression.hint.split('—').last.trim(),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ModeScreen(vpn: vpn)),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: BourassTheme.cyanAccent, size: 18),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF26A69A),
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class _SelectionCard extends StatelessWidget {
  final String category;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SelectionCard({
    required this.category,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF101726),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF1B2639)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              category,
              style: const TextStyle(
                color: Color(0xFF26A69A),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: BourassTheme.cyanAccent,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white38,
                  size: 22,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Faiz-parity 'Add Time' info sheet: unlimited per device (android_id),
/// no account, no reward ads, no quota clock. Purely informational —
/// Faiz gates this behind a backend quota; we simply have none.
void _showTimeSheet(BuildContext context, VpnEngine vpn) {
  showModalBottomSheet(
    context: context,
    backgroundColor: BourassTheme.cardBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add Time',
              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Row(
              children: [
                Icon(Icons.all_inclusive_rounded, color: BourassTheme.greenAccent, size: 22),
                SizedBox(width: 8),
                Text(
                  'UNLIMITED  •  no time limit',
                  style: TextStyle(color: BourassTheme.greenAccent, fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Time is bound to your device ID — no account needed. Connect as long as you want.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF101726),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF1B2639)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.badge_rounded, color: BourassTheme.cyanAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Device ID  ${vpn.deviceId}',
                      style: const TextStyle(color: BourassTheme.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.copy_rounded, color: BourassTheme.cyanAccent, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: vpn.deviceId));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          backgroundColor: BourassTheme.cardBg,
                          duration: Duration(seconds: 1),
                          content: Text('Device ID copied',
                              style: TextStyle(color: BourassTheme.cyanAccent)),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx),
                style: FilledButton.styleFrom(
                  backgroundColor: BourassTheme.cyanAccent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Done',
                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
