import 'package:flutter/material.dart';
import '../models/server.dart';
import '../services/vpn_engine.dart';
import '../theme/bourass_theme.dart';

class DnsTunScreen extends StatefulWidget {
  final VpnEngine vpn;
  const DnsTunScreen({super.key, required this.vpn});

  @override
  State<DnsTunScreen> createState() => _DnsTunScreenState();
}

class _DnsTunScreenState extends State<DnsTunScreen> {
  late DnsTunOption selected;
  late TextEditingController customCtrl;

  @override
  void initState() {
    super.initState();
    selected = widget.vpn.dnsTun;
    customCtrl = TextEditingController(text: widget.vpn.customDns);
  }

  @override
  void dispose() {
    customCtrl.dispose();
    super.dispose();
  }

  void _save() {
    widget.vpn.setDnsTun(selected, custom: customCtrl.text);
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
          'DNS TUN',
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
            'TUN DNS (tous protocoles)',
            style: TextStyle(color: BourassTheme.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'DNS des apps dans le tunnel (appliqué à la prochaine connexion).',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 12),
          ...DnsTunOption.values.map((opt) {
            final isSelected = opt == selected;
            return Container(
              margin: const EdgeInsets.only(bottom: 2),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF162132) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListTile(
                title: Text(
                  opt.label,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white70,
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                dense: true,
                onTap: () {
                  setState(() => selected = opt);
                },
              ),
            );
          }),
          if (selected == DnsTunOption.custom) ...[
            const SizedBox(height: 12),
            TextField(
              controller: customCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                labelText: 'Adresse DNS personnalisée',
                labelStyle: const TextStyle(color: BourassTheme.cyanAccent),
                filled: true,
                fillColor: const Color(0xFF101726),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
