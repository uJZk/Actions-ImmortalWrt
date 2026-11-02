# Factory defaults


Scripts under `files/etc/uci-defaults/` run once per flash in filename order and are then
deleted. Many settings use `set_if_unset` or change only a factory value to preserve
configuration across sysupgrade. Some deliberately overwrite preserved values on every
flash: for example, `90-luci-theme` corrects the theme, and `93-router-defaults` sets flow
offload, packet steering, qosify overhead, and disables the IPSec ESP and ISAKMP rules.
Check each script before assuming a setting is preserved.

- `90-luci-theme` -- corrects `luci.main.mediaurlbase`; this image drops the bootstrap
  theme.
- `91-unbound-odhcpd` -- wires up `maindhcp` / `leasetrigger`; without it the LAN gets no
  DHCPv4, or no hostname resolution.
- `92-flowtable-no-wandev` -- on a PPPoE uplink only, removes the physical port from the
  flowtable (see [runtime constraints](runtime-constraints.md)).
- `93-router-defaults` -- timezone/NTP, LAN domain, flow offload, fullcone, packet
  steering, qosify structural parameters, UPnP parameters, dae autostart, the two
  podman-stack cron entries.
- `94-unbound-private-tld` -- NXDOMAINs private-use TLDs locally. **Must skip
  `unbound.ub_main.domain`**: that value may have been preserved by sysupgrade from an
  older config (for example still `lan`), and negating it too breaks resolution of every
  LAN hostname with no error.
- `95-apk-mirror` -- rewrites `distfeeds.list` to a domestic mirror, because the official
  source is unusably slow from here. That file is generated at build time
  and overwritten by sysupgrade, so it must be rewritten on every flash. Before switching
  mirrors, confirm the target actually syncs `snapshots/` (`mirrors.ustc.edu.cn` carries
  only `releases/` and cannot be used).

**Deliberately not defaulted**, because they vary by line, are security policy, or depend
on things this repo does not ship: bandwidth (the values qosify and upnpd advertise), ULA,
SSH port and auth method, enabling UPnP, tailscale, any `/mnt` mount and container
definitions, dae node configuration, and **side access to the modem's admin page** (below).
`files/etc/podman-stack.d/` ships only a README, so `podman-stack update` does nothing by
default; `watchdog` needs no definition file and works on any running container with a
health probe.

On a PPPoE uplink the modem's admin page (usually `192.168.1.1`) is unreachable, because
`network.wan.device` itself carries no IPv4 address -- the PPPoE address is on
`pppoe-wan`. The fix is a static alias interface on that physical port, enrolled in the wan
zone:

```
config interface 'modem'
	option device 'eth1'          # = network.wan.device
	option proto 'static'
	option ipaddr '192.168.1.2/24'
```

Three points are each required. **No `gateway`**, or a second default route competes with
PPPoE. **SNAT is mandatory**: the modem has no route back to the LAN subnet, so untranslated
replies are dropped -- putting the interface in the wan zone gets this from the zone's
`masq`. **Enroll in the wan zone rather than a new zone**, which also inherits wan's
`input REJECT` so the modem side cannot reach the router. The physical port is usually
already in that zone via `wan6`, so it works without this -- but deleting `wan6` then
breaks it silently, hence writing it explicitly.

This is not a default because OpenWrt's factory LAN is `192.168.1.1/24`: on a device whose
LAN subnet has not been changed it collides with `br-lan`'s route, and the symptom is hard
to diagnose. `/etc/config/` is on sysupgrade's keep list, so configuring it once on the
device is enough.

