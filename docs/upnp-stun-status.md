# UPnP STUN work

The nftables build patches miniupnpd so STUN probe ports are added to
the dedicated fw4 input set `upnp_stun_ports`, rather than the UPnP forwarding
chain. The set's 60-second timeout bounds stale entries after a crash. Failed
rule installation aborts the probe instead of reporting a filtered upstream.
The LuCI `stun_allow_filtered` option defaults off; it generates
`ext_perform_stun=allow-filtered` only when STUN is enabled.

Local checks: the source patch applied to the 2.3.11 release source; the
configuration transformation was idempotent on the ImmortalWrt feed tested,
passed shell and JavaScript syntax checks, and emitted the expected values for
all four flag combinations. The temporary-rule helper was compiled and tested
with a mock nft command, including failed deletion and invalid input.

Outstanding: build the firmware and test on a router. Check fw4 input-set
syntax, live temporary-element creation and removal, expiry after process
termination, firewall reload, the four STUN replies on a suitable RFC 5780
server, UPnP mapping preservation, LuCI, and external reachability. Those local
checks did not use nft or a router and cannot prove those properties.

## Coordinated UPnP patches

`after-installing-feed.sh` calls `scripts/apply-upnp-patches.sh` once after feed
installation. The entry point applies:

- `scripts/patch-upnp.py`: STUN UCI/LuCI options and nftables mapping discovery
  in the LuCI rpcd plugin. The parser permits missing `iif` and packet/byte
  counters before DNAT, while retaining the existing mapping fields.
- `patches/100-nat-loopback.patch`: remove the interface match only after the
  guarded `upnp_prerouting` jump has been installed and verified.
- `patches/110-stun-input.patch`: use the dedicated expiring STUN input set.
- `patches/120-internal-client-fallback.patch` and
  `patches/130-ipv6-pinhole-client-fallback.patch`: preserve the IPv4 mapping and
  native IPv6 pinhole peer-address fallbacks from the remote main branch.
  See [fallback verification](upnp-client-fallback-status.md).

The image overlay still supplies the STUN set/input jump and hairpin return
SNAT under `files/usr/share/nftables.d/`. These are required companions to the
source patches, and are copied into the image by the normal build process.

Local regression checks: `python3 tests/test_upnp_patches.py` covers 24 rule
format combinations, unchanged upstream-anchor rejection, missing-guard
rejection, repeat application and restoration of a missing hairpin patch.
Shell syntax checks pass. The LuCI transformation also applies to the fetched
ImmortalWrt `luci.upnp` blob `f72b57b7ba84188b9b78854bf7ad0711394a0045`.
These checks do not execute rpcd/ucode or test live nftables. Router verification
still needs `ubus call luci.upnp get_status`, visible mappings in LuCI,
lease descriptions/expiry, and an actual hairpin connection.

## Wrap-up verification (2026-11-02)

Synced remote main's internal-client fallback changes before completing the
consolidation. The single entry point installs all four miniupnpd source
patches; regression checks compare each installed patch against its repository
source. `AGENTS.md` links this status document for continuation.

Passed: four regression tests (including 24 nftables formats), Bash syntax,
ShellCheck on both changed shell scripts, Actionlint with ShellCheck, and
`git diff --check`. No local firmware build was needed for these recipe changes.
The next build must exercise the coordinated patches against the rolling feeds;
live ubus, LuCI, STUN, IPv4/IPv6 fallback and NAT loopback checks remain open.
