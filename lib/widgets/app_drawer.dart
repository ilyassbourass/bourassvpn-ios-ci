import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/vpn_engine.dart';
import '../theme/bourass_theme.dart';
import '../screens/mode_screen.dart';
import '../screens/dns_tun_screen.dart';
import '../screens/hotspot_screen.dart';

class BourassDrawer extends StatelessWidget {
  final VpnEngine vpn;
  const BourassDrawer({super.key, required this.vpn});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFF0E1420),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A2230),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.shield_outlined, color: BourassTheme.cyanAccent, size: 36),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'BourassVPN',
                    style: TextStyle(
                      color: BourassTheme.cyanAccent,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Tunnel VPN',
                    style: TextStyle(color: BourassTheme.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1B5E20).withOpacity(0.3),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF22E58A).withOpacity(0.4)),
                        ),
                        child: const Text(
                          'v1.0.0',
                          style: TextStyle(color: Color(0xFF22E58A), fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF004D40).withOpacity(0.3),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: BourassTheme.cyanAccent.withOpacity(0.4)),
                        ),
                        child: const Text(
                          'ams-1',
                          style: TextStyle(color: BourassTheme.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 8),
            // Menu Items
            _DrawerTile(
              icon: Icons.tune_rounded,
              title: 'Mode',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => ModeScreen(vpn: vpn)));
              },
            ),
            _DrawerTile(
              icon: Icons.dns_outlined,
              title: 'DNS TUN',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => DnsTunScreen(vpn: vpn)));
              },
            ),
            _DrawerTile(
              icon: Icons.wifi_tethering_rounded,
              title: 'Hotspot',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => HotspotScreen(vpn: vpn)));
              },
            ),
            _DrawerTile(
              icon: Icons.cell_tower_rounded,
              title: 'Réseau',
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: BourassTheme.cardBg,
                    content: Text(
                      'Réseau: WiFi / Inwi 4G • IP: ${vpn.localIp}',
                      style: const TextStyle(color: BourassTheme.cyanAccent),
                    ),
                  ),
                );
              },
            ),
            _DrawerTile(
              icon: Icons.fingerprint_rounded,
              title: 'Copier ID appareil',
              onTap: () {
                Clipboard.setData(ClipboardData(text: vpn.deviceId));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    backgroundColor: BourassTheme.cardBg,
                    content: Text(
                      'ID appareil copié !',
                      style: TextStyle(color: BourassTheme.cyanAccent),
                    ),
                  ),
                );
              },
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Divider(color: Colors.white12, height: 1),
            ),
            _DrawerTile(
              icon: Icons.shield_outlined,
              title: 'Politique de confidentialité',
              onTap: () {
                Navigator.pop(context);
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: const Color(0xFF141C2B),
                    title: const Text('Confidentialité', style: TextStyle(color: BourassTheme.cyanAccent)),
                    content: const Text(
                      'BourassVPN respecte votre vie privée. Aucun journal de connexion ou de navigation n''est conservé.',
                      style: TextStyle(color: Colors.white70),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('FERMER', style: TextStyle(color: BourassTheme.cyanAccent)),
                      ),
                    ],
                  ),
                );
              },
            ),
            _DrawerTile(
              icon: Icons.send_rounded,
              title: 'Telegram @Bourassvpn',
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    backgroundColor: BourassTheme.cardBg,
                    content: Text(
                      'Telegram: https://t.me/Bourassvpn',
                      style: TextStyle(color: BourassTheme.cyanAccent),
                    ),
                  ),
                );
              },
            ),
            const Spacer(),
            const Divider(color: Colors.white12, height: 1),
            _DrawerTile(
              icon: Icons.exit_to_app_rounded,
              title: 'Quitter l\'application',
              onTap: () {
                SystemNavigator.pop();
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  const _DrawerTile({required this.icon, required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70, size: 22),
      title: Text(
        title,
        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
      ),
      dense: true,
      visualDensity: const VisualDensity(vertical: -1),
      onTap: onTap,
    );
  }
}
