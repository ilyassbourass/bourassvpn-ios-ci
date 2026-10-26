import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/dashboard.dart';
import 'services/vpn_engine.dart';
import 'theme/bourass_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF090D16),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const BourassVpnApp());
}

class BourassVpnApp extends StatefulWidget {
  const BourassVpnApp({super.key});

  @override
  State<BourassVpnApp> createState() => _BourassVpnAppState();
}

class _BourassVpnAppState extends State<BourassVpnApp> {
  late final VpnEngine vpn;

  @override
  void initState() {
    super.initState();
    vpn = VpnEngine();
  }

  @override
  void dispose() {
    vpn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BourassVPN',
      debugShowCheckedModeBanner: false,
      theme: BourassTheme.themeData,
      home: DashboardScreen(vpn: vpn),
    );
  }
}
