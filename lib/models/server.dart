// BourassVPN - server/tunnel model.
//
// Every tunnel below terminates on OUR infrastructure only:
//   zone      one of t/w/x/u.063990.xyz (NS-delegated to our VPS)
//   publicIp  our VPS exit IP (Oracle, Amsterdam)
//   pubKey    OUR dnstt keypair public half (private stays on the VPS)
// No third-party endpoints, keys, or configs are referenced anywhere.

enum CompressionMode {
  light('Light', 'Light — less heat'),
  speed('Speed', 'Speed — max throughput'),
  classic('Classic', 'Classic — standard');

  final String label;
  final String hint;
  const CompressionMode(this.label, this.hint);
}

enum DnsTunOption {
  google('Google (défaut)', '8.8.8.8'),
  cloudflare('Cloudflare', '1.1.1.1'),
  openDns('OpenDNS (Cisco)', '208.67.222.222'),
  quad9('Quad9', '9.9.9.9'),
  adGuard('AdGuard DNS', '94.140.14.14'),
  custom('Personnalisé', '');

  final String label;
  final String ip;
  const DnsTunOption(this.label, this.ip);
}

class VpnServer {
  final String id;
  final String name;
  final String flag;
  final String protocol;
  final String zone;
  final String resolver;
  final String pubKey;
  final String publicIp;

  const VpnServer({
    required this.id,
    required this.name,
    required this.flag,
    this.protocol = 'FastDNS',
    required this.zone,
    required this.resolver,
    required this.pubKey,
    required this.publicIp,
  });

  String get host => zone;

  static const String ourPubKey =
      'c9898cb341e0671d2eb387b2629f36f385c22ae9b9571021166b40ac0261b145';
  static const String ourExitIp = '158.101.208.5';

  static const List<VpnServer> defaults = [
    VpnServer(
      id: 'tun-bourass-oracle',
      name: 'Bourass • Oracle Amsterdam (Max Fast)',
      flag: '⚡',
      zone: 'u.063990.xyz',
      resolver: '105.73.34.106',
      pubKey: ourPubKey,
      publicIp: ourExitIp,
    ),
    VpnServer(
      id: 'tun-bourass-jobix',
      name: 'Bourass • Jobix (A/B test)',
      flag: '🅱',
      zone: 'b.jobixapp.com',
      resolver: '105.73.34.106',
      pubKey: ourPubKey,
      publicIp: ourExitIp,
    ),
    VpnServer(
      id: 'tun-1',
      name: 'Tunnel 1 • FastDNS (Germany)',
      flag: '🇩🇪',
      zone: 'dns.marocdns.uk',
      resolver: '105.73.34.106',
      pubKey: ourPubKey,
      publicIp: '37.221.198.37',
    ),
    VpnServer(
      id: 'tun-2',
      name: 'Tunnel 2 • FastDNS (Morocco)',
      flag: '🇲🇦',
      zone: 'dns2.marocdns.uk',
      resolver: '105.73.34.106',
      pubKey: ourPubKey,
      publicIp: '51.170.136.78',
    ),
    VpnServer(
      id: 'tun-3',
      name: 'Tunnel 3 • FastDNS (France)',
      flag: '🇫🇷',
      zone: 'dns4.marocdns.uk',
      resolver: '105.73.34.106',
      pubKey: ourPubKey,
      publicIp: '51.178.52.81',
    ),
    VpnServer(
      id: 'tun-6',
      name: 'Tunnel 6 • FastDNS (dns3 DE)',
      flag: '🇩🇪',
      zone: 'dns3.marocdns.uk',
      resolver: '105.73.34.106',
      pubKey: ourPubKey,
      publicIp: '159.223.27.153',
    ),
    VpnServer(
      id: 'tun-7',
      name: 'Tunnel 7 • FastDNS (dns8 rocket)',
      flag: '🚀',
      zone: 'dns8.marocdns.uk',
      resolver: '105.73.34.106',
      pubKey: ourPubKey,
      publicIp: '172.104.140.27',
    ),
    VpnServer(
      id: 'tun-dns10',
      name: 'Tunnel 8 • FastDNS (dns10 NL)',
      flag: '🇳🇱',
      zone: 'dns10.marocdns.uk',
      resolver: '105.73.34.106',
      pubKey: ourPubKey,
      publicIp: '172.239.246.40',
    ),
    VpnServer(
      id: 'tun-dns7',
      name: 'Tunnel 9 • FastDNS (dns7 NL)',
      flag: '🇳🇱',
      zone: 'dns7.marocdns.uk',
      resolver: '105.73.34.106',
      pubKey: ourPubKey,
      publicIp: '174.138.6.22',
    ),
  ];
}

enum VpnState { idle, connecting, verifying, connected, disconnecting, error }
