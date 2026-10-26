import 'package:flutter/material.dart';
import '../services/vpn_engine.dart';
import '../theme/bourass_theme.dart';

class FastDnsResolverDialog extends StatefulWidget {
  final VpnEngine vpn;
  const FastDnsResolverDialog({super.key, required this.vpn});

  static void show(BuildContext context, VpnEngine vpn) {
    showDialog(
      context: context,
      builder: (_) => FastDnsResolverDialog(vpn: vpn),
    );
  }

  @override
  State<FastDnsResolverDialog> createState() => _FastDnsResolverDialogState();
}

class _FastDnsResolverDialogState extends State<FastDnsResolverDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.vpn.resolver);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF141C2B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'FastDNS resolver',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              cursorColor: BourassTheme.cyanAccent,
              decoration: InputDecoration(
                labelText: 'Custom DNS resolver',
                labelStyle: const TextStyle(color: BourassTheme.cyanAccent, fontSize: 13),
                floatingLabelBehavior: FloatingLabelBehavior.always,
                helperText: 'IPv4 wa7ed wla jouj mfro9in b comma',
                helperStyle: const TextStyle(color: Colors.white38, fontSize: 11),
                filled: true,
                fillColor: const Color(0xFF0C121E),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF1D283C)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: BourassTheme.cyanAccent),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'CANCEL',
                    style: TextStyle(color: BourassTheme.cyanAccent, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    _controller.text = '105.73.34.106,105.73.34.105';
                  },
                  child: const Text(
                    'AUTO',
                    style: TextStyle(color: BourassTheme.cyanAccent, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    widget.vpn.setResolver(_controller.text);
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: BourassTheme.cyanAccent,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  ),
                  child: const Text(
                    'SAVE',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
