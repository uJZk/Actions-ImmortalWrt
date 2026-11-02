# Runtime constraints

These constraints can fail silently; check them when changing the image or router behavior.

- **Dropping `luci-theme-bootstrap` takes a feed patch *and* a uci-default.** `luci-light`
  names it as a hard dependency, so unchecking it in `.config` is selected straight back by
  `make defconfig`; `after-installing-feed.sh` rewrites the dependency to
  `+luci-theme-footstrap` in `feeds/luci/collections/luci-light/Makefile` -- the real file,
  since `package/feeds/luci/luci-light` is only a symlink -- and warns if that string is
  gone. That alone still ships a broken UI: `luci-base` installs `/etc/config/luci` with
  `mediaurlbase=/luci-static/bootstrap` already set, and footstrap's own uci-default writes
  the option only when *missing*, so first boot points at a directory this image does not
  contain. `files/etc/uci-defaults/90-luci-theme` overwrites it unconditionally and is
  numbered to run after it.

- **`DISTRIB_VERSIONS` is a runtime contract with deployed routers.** The build writes
  `<12-digit timestamp>_<short sha>` into `/etc/openwrt_release`;
  `files/usr/bin/easyupdate.sh` parses exactly 12 digits from it and from the release tag
  and compares them as strings -- correct only because `%Y%m%d%H%M` is zero-padded and
  monotonic. Changing that `date` format breaks OTA on every router already in the field.

- **Image format is coupled to the OTA updater.** `.config` builds EFI + EROFS plus a
  rootfs tarball; SquashFS, ext4, and BIOS GRUB are off. `easyupdate.sh` picks
  `combined-efi.img.gz` vs `combined.img.gz` by probing `/sys/firmware/efi/` against the
  release's asset list, derives the filename from the URL basename, reverse-parses
  `DISTRIB_GITHUB` by fixed field index for the API URL, and fetches `sha256sums` by
  substituting that basename in place. Enabling BIOS images or another rootfs changes asset
  names and silently breaks OTA.

- **Scripts under `files/` may only use busybox applets this `.config` enables.** OpenWrt's
  busybox is a trimmed build and `BUSYBOX_CONFIG_<APPLET>` defaults to the
  `BUSYBOX_DEFAULT_<APPLET>` lines in `.config`. `nproc` is off and `coreutils-nproc` is not
  installed, so a script calling it gets an empty substitution; inside `$(( ))` that is an
  arithmetic syntax error aborting the assignment, which combined with a `2>/dev/null` on
  the write makes the whole script a silent no-op. Grep `.config` for
  `BUSYBOX_DEFAULT_<APPLET>` before using anything beyond the obvious, and prefer sysfs
  where one exists (CPU count: count `/sys/devices/system/cpu/cpu[0-9]*`).

- **`fstrim` and `f2fsck` exist for a partition this repo never creates.** The deployed
  router carries the disk's remaining space as one f2fs partition holding podman's
  graphroot; that mount and the podman paths live in config files sysupgrade preserves on
  its own. What the image must supply is the two binaries: the volume is mounted `nodiscard`
  with a weekly `fstrim` from cron, and `fstab`'s `check_fs` needs `fsck.f2fs`. Neither is a
  busybox applet here, and an `apk`-installed copy would not survive sysupgrade, so both are
  compiled in. Dropping either package silently costs TRIM and the mount-time check.
  - **f2fs compression is deliberately off.** `config-6.18` carries
    `# CONFIG_F2FS_FS_COMPRESSION is not set` as an explicit answer: this file replaces
    upstream's subtarget config and the symbol is prompted, so deleting the line strands
    `syncconfig` on the question. Enabling it saves no *reported* space -- f2fs keeps the
    saved blocks reserved to the file so a later overwrite of a compressed cluster can never
    hit `ENOSPC`, and both `du` and `df` still charge the full size. Only
    `F2FS_IOC_RELEASE_COMPRESS_BLOCKS` (`f2fs_io release_cblocks`, in the unselected
    `f2fs-tools`) returns them, and a released file becomes unwritable -- a write-once model
    that fits neither podman's overlay store nor any live data.

- **Kernel options that only build a mechanism still need runtime activation, and RPS/RFS
  are activated from uci, not from `files/etc`.** `CONFIG_XPS` and `CONFIG_NET_FLOW_LIMIT`
  ship an all-zero CPU mask; `files/usr/libexec/arm-xps-flowlimit` arms `xps_cpus` and
  `net.core.flow_limit_cpu_bitmap`, and nothing else. It runs from **two** hotplug hooks --
  `net` on `add` and `iface` on `ifup` -- because the `add` hook alone does not stick: the
  physical NICs' `xps_cpus` read back `0` after boot while the global bitmap set earlier in
  the same script holds. It selects devices by *shape* (a `device` symlink present, no
  `lower_*`), not by name: a name blacklist lets `tailscale0` through, and that device's
  `xps_cpus` reads back empty and swallows writes, so a run can arm no queue at all while
  looking like it worked. `CONFIG_RPS`/`CONFIG_RFS_ACCEL` are **not** its business:
  OpenWrt's `packet_steering` service owns `rps_cpus` and `rps_flow_cnt` and overwrites them
  unconditionally *after* every net hotplug event, so a hotplug handler cannot win that
  race. Configure them through `network.globals.packet_steering` (`2` = spread over every
  CPU) and `network.globals.steering_flows`, which also puts them where sysupgrade keeps
  them; leave them unset and the service pins each NIC to a *single* CPU and writes
  `rps_flow_cnt=0`, disabling RFS with no log line anywhere. The third RFS knob, global
  `net.core.rps_sock_flow_entries`, is set by ImmortalWrt's `/etc/init.d/autocore` -- don't
  set it again. `flow_limit_cpu_bitmap` stays in the hotplug handler rather than `sysctl.d`
  because physical NICs register during `kmodloader`, which can run before
  `/etc/init.d/sysctl` (START=11).

- **DNS is unbound and DHCP is odhcpd; dnsmasq is not built.** `.config` deselects
  `dnsmasq-full` and swaps `odhcpd-ipv6only` for the full `odhcpd`: dnsmasq was the DHCPv4
  server, so removing it without that swap leaves the LAN with no DHCP at all. Upstream
  supports the pairing through `/usr/lib/unbound/odhcpd.sh`, but wiring it takes three uci
  settings nothing sets correctly by default, and this repo ships all three:
  `unbound.@unbound[0].dhcp_link='odhcpd'` in `files/etc/config/unbound` (upstream ships
  `none`), and `dhcp.@odhcpd[0].leasetrigger`/`maindhcp` from
  `files/etc/uci-defaults/91-unbound-odhcpd`. Leave `dhcp_link` at `none` and DNS works
  while every LAN hostname stops resolving, with no error anywhere. `maindhcp` needs its own
  uci-default because odhcpd's `15_odhcpd` derives it from whether dnsmasq exists only on a
  *first* install; once sysupgrade has preserved `/etc/config/dhcp` it takes its migration
  branch and exits early, so a box upgraded from a dnsmasq-era image keeps `maindhcp=0` and
  hands out no DHCPv4.
  - **Do not swap unbound for smartdns.** `unbound.sh` guards every dnsmasq path with an
    existence check, so an absent dnsmasq degrades to `dhcp_link=none`. smartdns's init has
    no such check, and its whole mechanism for taking over port 53 runs through
    `dhcp.@dnsmasq[0]` -- a section that does not exist once dnsmasq is deselected, so the
    takeover silently no-ops and smartdns stays on its default 6053.
  - **Forwarding to a resolver on `127.0.0.1` needs `option dns_assist 'unprotected-loop'`
    on the zone, and fails silently without it.** `unbound.sh` classifies each `list server`
    before emitting the zone, and a `127.*` address falls through to a `case` arm that does
    nothing, so it is dropped from the generated `forward-zone` with no message. The escape
    hatch is the `local_subnet` branch, which needs `dns_ast > 0`; `dns_assist` only reaches
    that for a handful of named helpers or the catch-all `unprotected-loop`. That same flag
    emits `do-not-query-localhost: no` -- unbound defaults to `yes`, so even a server
    surviving the filter would be refused at query time. The name is a real warning: nothing
    then detects a loop, so whatever sits on that port must never forward back to unbound.
  - **The factory default forwards to a fixed public resolver -- neither recursing nor
    following the ISP.** The `fwd_isp` section pins `resolv_conf '0'` plus one
    `list server`. Recursing from the root is slow and easily tampered with on mainland
    links; following the ISP makes behaviour depend on whether the uplink is DHCP or PPPoE
    (that decides whether `resolv.conf.auto` has anything in it), and many ISP resolvers
    inject into results. `fallback '0'` sets `forward-first: no`, so a dead upstream fails
    outright rather than quietly recursing, which would answer differently. To follow the
    ISP again, set `resolv_conf` back to `'1'` and delete the `list server`. Note the
    forwarder list is a *set*, not a priority order: unbound sends to whichever upstream its
    RTT estimate rates fastest, so listing one first buys nothing.

- **`/etc/rc.d` runs in filename lexical order, not by START value, and mounts are not
  ready until after rc.d finishes.** Lexical order means
  `S100container-*` < `S10storage-guard` < `S11fstab` < ... < `S99podman`, so services with
  START >= 100 run first. Meanwhile `S11fstab`'s `block mount` runs `fsck.f2fs` (from
  `fstab`'s `check_fs`) before mounting, completing only after the whole rc.d sequence: at
  S98 the mountpoint is still empty, and `S99podman` starts right then. podman hard-fails
  when the graphroot is not writable **and procd does not retry**, so no container starts;
  a writable graphroot with the volume not yet mounted is worse -- the store is created on
  the rootfs and then hidden under the volume, with no visible symptom. Putting podman's
  storage on a data disk therefore needs a service that waits for the mount in the
  background; START order cannot do it. This repo's defaults presume no `/mnt` mount and
  ship no such script -- read this before adding a data disk.

- **Do not set `net.netfilter.nf_conntrack_max`.** The kernel sizes the hash once at module
  load and derives the ceiling from it, so a sysctl override moves the ceiling without
  resizing the hash and on this target can only lower it. The mechanism is spelled out in
  the header of `files/etc/sysctl.d/99-router-tuning.conf`; that file must also not fight
  the timeouts upstream's `11-nf-conntrack.conf` already sets.
- The kernel partition is small relative to the rootfs
  (`CONFIG_TARGET_KERNEL_PARTSIZE`/`CONFIG_TARGET_ROOTFS_PARTSIZE`); adding many kmods can
  overflow it.

- **Software flow offloading does not bypass the *egress* qdisc, but on a PPPoE WAN it
  bypasses *ingress* shaping entirely.** Only *hardware* offloading skips the qdisc; LuCI's
  UI text hedges more broadly than the kernel datapath does. The flowtable is attached to
  the physical WAN device as well as to `pppoe-wan`, so an inbound packet is decapsulated
  and forwarded to `br-lan` by the ingress-hook fast path without `pppoe-wan` ever being
  traversed -- and qosify's ingress classifier and `mirred` redirect live on exactly that
  netdev's `clsact`. Egress survives, since the upload stream still leaves through
  `pppoe-wan`'s root qdisc. So **downstream bufferbloat control and software flow offload
  are mutually exclusive** unless the physical WAN device is trimmed out of the flowtable.
  - `files/etc/uci-defaults/92-flowtable-no-wandev` does that trimming. It reads
    `network.wan.proto` and **only when it is `pppoe`** writes
    `/usr/share/fw4-extra/flowtable-no-wandev.nft` (a
    `delete flowtable inet fw4 ft { devices = { <network.wan.device> } }`) and registers it
    as a fw4 include. On any other uplink it deletes both, because a DHCP/static WAN has no
    physical-plus-dialer pair and removing its only WAN device would disable WAN-direction
    offload altogether.
  - Three details of that include are load-bearing, and each fails as a *ruleset-wide*
    syntax error that makes fw4 refuse to load anything: `position` must be
    `ruleset-append`, since `table-*` and `chain-*` splice the text inside the table where a
    top-level `delete flowtable` is invalid; the file must not live in `/etc/nftables.d/`,
    which is auto-scanned into the table regardless of any include section, so putting it
    there breaks the ruleset and removing the uci section does not fix it; and `path` must
    never dangle -- the uci section survives sysupgrade while `/usr/share` does not, so the
    snippet is regenerated on *every* flash, which is also what lets the device name come
    from uci.
  - Replacing the flowtable wholesale is not an option: `nft` returns `Resource busy` while
    rules reference it, and re-adding is additive.
  - Keep `flow_offloading_hw` off. The r8168 NICs have no hardware flowtable, so fw4 emits
    `flags offload`, the kernel accepts it, and no `[HW_OFFLOAD]` conntrack entry ever
    appears -- the knob reads as enabled and does nothing.
  - Software offload costs conntrack accounting: an offloaded flow stops updating its
    `packets=`/`bytes=` counters, so anything reading them via ctnetlink under-reports.
    That is why `nlbwmon` is deselected.

- **Deselecting `CONFIG_PACKAGE_daed` is not enough to keep daed out of the image.**
  `luci-app-daede` picks its backend through a kconfig `choice` whose default is
  `PACKAGE_luci-app-daede_daed`, and its `DEPENDS` is
  `+PACKAGE_luci-app-daede_dae:dae +PACKAGE_luci-app-daede_daed:daed`, so leaving that
  choice unset lets `make defconfig` pull `daed` back in past an explicit
  `# CONFIG_PACKAGE_daed is not set`. `.config` therefore also carries
  `CONFIG_PACKAGE_luci-app-daede_dae=y`. The symptom is silent: the build succeeds and the
  image simply contains both backends, visible only in the manifest.

- **dae and qosify share one `clsact` on the WAN device, and coexist only because dae
  returns `TC_ACT_PIPE`.** A cls_bpf program's return value ends the filter chain for
  everything except `TC_ACT_PIPE`, which maps to `TC_ACT_UNSPEC` so classification moves on
  to the next filter. dae sits at tc priorities 1/2 and qosify at `QOSIFY_PRIO_BASE`, so
  dae runs first and any other return value from it cuts qosify out. Older dae returned
  `TC_ACT_OK` for forwarded packets on the WAN *egress* path, which silently killed
  qosify's egress DSCP marking: cake kept shaping, but tins came from whatever DSCP the LAN
  client set. The feed ships rolling dated snapshots, so **if DSCP classification ever goes
  quietly wrong, check that return first** -- `tc filter show dev <wan> egress` shows both
  programs attached either way, so the symptom is bad tins, not a missing filter.
  sqm-scripts is not an escape: it installs the legacy `ingress` qdisc, and since
  `TC_H_CLSACT == TC_H_INGRESS` there is one qdisc slot per device, so sqm and dae on the
  same interface make each other's second `qdisc add` fail with `EEXIST`.

- **UPnP NAT loopback is assembled from two halves; doing only one DNATs intra-LAN traffic
  on the same port.** miniupnpd implements no hairpin, and every DNAT rule it writes carries
  `iif <ext_ifname>`, which a LAN client reaching the router's own public address can never
  match. Three interdependent pieces fix it: (1) `scripts/apply-upnp-patches.sh` installs
  `patches/100-nat-loopback.patch` into the miniupnpd feed so `configure` stops
  defining `USE_IFNAME_IN_RULES`, dropping the `iif` match; (2) the same script replaces the
  unconditional `jump upnp_prerouting` in the package's
  `files/nftables.d/chain-post/dstnat/20-miniupnpd.nft` with a guard
  (`fib daddr type local ip daddr != 192.168.0.0/24 ip daddr != 100.64.0.0/10`); (3)
  `files/usr/share/nftables.d/chain-post/srcnat/25-upnp-hairpin.nft` supplies the return
  SNAT. **The order is a safety property, not style**: the script edits the .nft first and
  writes the patch only on success, because patching without the guard leaves rules matching
  proto+dport alone, so LAN-to-LAN traffic on that port is DNATed to the mapping's target
  host; the reverse order is harmless. The guard uses `fib` rather than a hardcoded public
  address because that address changes on PPPoE redial while
  `/etc/hotplug.d/iface/50-miniupnpd` restarts miniupnpd only when `ext_ifname` *changes*
  (the device name does not), so a hardcoded address fails silently after the next dial.
  Without the return SNAT nothing connects: after DNAT the server replies at layer 2 from
  the original source address while the client waits on the public address, and resets.
  Unlike `flowtable-no-wandev.nft`, these two snippets need no uci entry -- fw4
  auto-includes anything under `/usr/share/nftables.d/chain-post/<chain>/` -- but they are
  image content, so sysupgrade does not preserve them.

- **LuCI UPnP discovery must support the hairpin rule format.** The upstream
  `luci.upnp` rpcd plugin expects `iif` and no counter before DNAT, so removing
  `iif` for hairpin can leave `get_status` empty even with active mappings.
  `scripts/patch-upnp.py` allows an optional interface and counter, preserving
  the four capture fields used for protocol, external port and destination.
  It also accepts `ip protocol` and `meta l4proto` protocol expressions.
  Feed anchor drift fails the build instead of silently shipping the old parser.

- **qosify silently ignores `overhead` unless `overhead_type` is `manual`.** Its init
  script reads the byte count only inside the `manual` branch of the `overhead_type` case;
  every named encapsulation (`ethernet`, `docsis`, `pppoe-ptm`, ...) just forwards that
  keyword to cake. So "ethernet plus 8 bytes for PPPoE" cannot be expressed the way the UI
  suggests -- selecting `ethernet` yields `overhead 38 mpu 84` and discards the 8. PPPoE
  over Ethernet needs `manual` with `overhead 46 mpu 84`: 14 header + 4 FCS + 8
  preamble/SFD + 12 inter-frame gap (cake's `ethernet`) plus 6 PPPoE + 2 PPP. The qdisc
  sits on `pppoe-wan`, where `skb->len` is the IP length, so none of that framing is
  otherwise counted.

- **Don't add a build-time patch for the geoip/geosite source -- `luci-app-daede` owns that
  at runtime.** Its UI writes `daede.config.geoip_url`/`geosite_url`, `update-geo.sh`
  consumes them and already defaults to Loyalsoldier/v2ray-rules-dat, and the refresh writes
  the same `/usr/share/v2ray/{geoip,geosite}.dat` that `v2ray-geodata` seeds at install
  time. Patching the package Makefile decides the same thing in a second place, with nothing
  to catch a drift. The package stays selected only to provide data on first boot.

- **qosify needs `ip-tiny` but does not depend on it.** It shells out to
  `ip link add ... type ifb` to build its ingress device; busybox's `IPLINK` applet is off
  here, and the package's `DEPENDS` names only `tc`. Dropping `CONFIG_PACKAGE_ip-tiny`
  costs ingress shaping silently.

- **A broken rpcd ucode plugin fails silently -- `logread` shows nothing.** ucode resolves
  `import` names at *compile* time, so one missing export makes the whole script fail to
  compile and rpcd skips it without logging, registering no ubus object. Every LuCI call
  against it then returns `-32000 Object not found` (genuinely "not registered"; an ACL
  problem reports `Access denied`). To see the real error, run the plugin by hand:
  `ucode -R /usr/share/rpcd/ucode/<name>`. An older `luci-app-podman` revision had
  this problem with `init_action`; current upstream uses ubus instead. The package
  is cloned from its default branch without a pin against a rolling LuCI version.

- **`podman-stack` uses explicit container definitions.** LuCI's image updater
  reconstructs a subset of inspect settings and cannot guarantee all options are
  preserved. `update` uses `/etc/podman-stack.d/*.conf`, retains the original
  container until its replacement starts, and attempts rollback on failure. It retains
  one previous image with its own tag and only removes older managed images if
  untagged and unused. The
  watchdog probes running containers and uses Podman restart policies and
  `StoppedByUser` for recovery. It uses Podman 5.8 `stop --service` for its own
  restarts so explicit manual stops remain distinguishable.
  The definition README documents crash recovery and limitations. LuCI and
  podman-stack do not share a lock; avoid concurrent updates. Autostart belongs
  to the procd services generated by luci-app-podman.

- **The shipped `registries.conf` points docker.io at a public mirror, as a mirror and not
  a `location` rewrite.** Pulling docker.io from inside mainland China needs one, but
  public mirrors keep shutting down, so the fallback to docker.io itself must stay
  reachable: `[[registry.mirror]]` tries the mirror first and falls back, a `location`
  rewrite would not. The `[[registry]]` block must spell out `location` even though it is
  the identity -- c/image refuses to load the whole file if a block has no `location` and a
  non-wildcard prefix, and a broken registries.conf fails every pull with an error naming
  the config rather than the mirror.

- **podman itself has no build-time config file.** `/etc/containers/storage.conf`,
  `containers.conf`, and `networks/podman.json` are set up by hand after flashing; nothing
  in `files/` ships a default. Point the storage path at persistent, non-rootfs storage
  before pulling images, given how little room the rootfs partition leaves.
  `luci-app-podman` (third-party) gives a LuCI UI but is unrelated to the official `podman`
  package and does not configure it. It is `git clone`d into `package/luci-app-podman`
  rather than added as a feed because that repo's root *is* the package, while OpenWrt's
  feed indexer only recognises `<feed>/<pkg>/Makefile`, so `src-git`-ing it breaks index
  construction outright. `Zerogiven-OpenWRT-Packages/package-feed`, the repo that *looks*
  like its feed, is a prebuilt-apk binary repository with no package Makefiles; adding it
  with `src-git` silently yields zero packages.
