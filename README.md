# BourassVPN iOS

iOS port of BourassVPN — the FastDNS Layer-3 DNS-tunnel engine (Swift port of
the deployed Android `FastDnsEngine.kt`) with Faiz's servers + our Oracle
backend, end to end. Distribution: **unsigned IPA**, signed at install time
with the user's Apple Developer certificate (NetworkExtension entitlement).

See `../BOURASSVPN_IOS_BUILD_PLAN.md` in the parent project for the full plan
and validation ladder.

## Layout

- `Sources/BourassEngine/` — the engine (wire, crypto, zstd, lanes, watchdogs)
- `Sources/CZstd/` — vendored zstd 1.5.7 (BSD)
- `Tools/BourassCLI/` — live validation harness (`handshake` / `transfer`)
- `Tests/BourassEngineTests/` — S1 golden vectors (deterministic, fixed IVs)
  - `make_fixtures.py` regenerates `Fixtures/golden.json` (needs python3 +
    `zstandard` + `cryptography`)
- `ios/` — Flutter host app + PacketTunnelProvider extension (M3)

## Wire protocol (sources of truth)

1. `FastDnsEngine.kt` (Android, deployed & tuned)
2. `.freebuff/work/v2_e2e.py`, `v2_comp_test.py` (standalone oracles, proven live)
3. `remote_fastdns_srv.go` (our Oracle server)

Key facts: v2 handshake `0h.<b32(27B)>.<zone>` qtype 10 + panel token in EDNS0
0xFDE9, **flag byte 0x13** (not 0x12 — that was the 30 s freeze), session key
`HMAC(HMAC(master,sub), keyDev+NUL+sid+NUL+cert)`, uplink = zstd(8pkt/2500B
batch) → per-chunk AES-GCM `seq,i,n` 81-byte chunks → `0-<b32>.s<sid>.<zone>`,
downlink = `0xf1` envelope → zstd → `[u16 len + pkt]*`, poll = keepalive only.

## Validation

- S1 (CI, required): `swift test` — byte-exact goldens + roundtrips
- S2 (CI, non-blocking): `BourassCLI transfer --zone u.063990.xyz` — full
  engine, real ICMP round trip through the Oracle VPS
- S3 (manual dispatch): same against Faiz `dns.marocdns.uk` (token lease)
- S4+: on-device (see plan)
