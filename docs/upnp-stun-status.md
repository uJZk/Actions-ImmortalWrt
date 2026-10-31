# UPnP STUN work

The nftables build patches miniupnpd 2.3.11 so STUN probe ports are added to
the dedicated fw4 input set `upnp_stun_ports`, rather than the UPnP forwarding
chain. The set's 60-second timeout bounds stale entries after a crash. Failed
rule installation aborts the probe instead of reporting a filtered upstream.
The LuCI `stun_allow_filtered` option defaults off; it generates
`ext_perform_stun=allow-filtered` only when STUN is enabled.

Local checks: the source patch applies to the 2.3.11 release source; the
configuration transformation is idempotent on the current ImmortalWrt feed,
passes shell and JavaScript syntax checks, and emits the expected values for
all four flag combinations. The temporary-rule helper was compiled and tested
with a mock nft command, including failed deletion and invalid input.

Outstanding: build the firmware and test on a router. Check fw4 input-set
syntax, live temporary-element creation and removal, expiry after process
termination, firewall reload, the four STUN replies on a suitable RFC 5780
server, UPnP mapping preservation, LuCI, and external reachability. The test
environment has no nft executable or router and cannot prove those properties.
