# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

## What this repo is

A config-only GitHub Actions build repo for x86/64 ImmortalWrt firmware (derived from
P3TERX/Actions-OpenWrt). There is **no application source here** -- CI shallow-clones
upstream ImmortalWrt into `openwrt/` and injects this repo's `.config`, `config-6.18`,
`files/`, and the two feed-patch scripts into that tree. Editing anything here changes a
build recipe, not a program.

Both `before-installing-feed.sh` and `after-installing-feed.sh` execute with cwd
`openwrt/`, so their paths are relative to the upstream tree, not to this repo.

`README.md` is the outward-facing summary: what the image contains, how to dispatch a
build, and the repository layout. This file is the constraints that are not visible from
the file you are editing. Keep package-selection rationale in one place, not both.

## Verifying changes

There is no local build. The verification loop is running the workflow under
[`act`](https://github.com/nektos/act), which is not installed here -- run it via the
[`efrecon/act`](https://hub.docker.com/r/efrecon/act) image on podman, pointed at the
podman socket. In this unprivileged-LXC environment podman's default systemd cgroup manager
makes `crun` fail with `sd-bus call: ... Input/output error`, so the run needs
`--cgroup-manager=cgroupfs --cgroups=disabled`. `-P ubuntu-latest=...` is required too:
without it act prompts for a runner image size and fails with EOF, since there is no TTY.

```bash
podman run --rm \
  --network=host \
  --cgroup-manager=cgroupfs \
  --cgroups=disabled \
  -v "$(pwd)":"$(pwd)":Z \
  -v "$XDG_RUNTIME_DIR/podman/podman.sock":/var/run/docker.sock \
  -w "$(pwd)" \
  docker.io/efrecon/act:latest \
  workflow_dispatch -W .github/workflows/build-immortalwrt.yml \
  -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
```

Lint first -- it catches YAML and shell mistakes in seconds instead of after a long build:

```bash
SHELLCHECK_OPTS="-e SC2086,SC2046,SC2206,SC2128,SC2178,SC2154" actionlint
shellcheck -S warning before-installing-feed.sh after-installing-feed.sh \
  files/usr/bin/easyupdate.sh files/usr/bin/podman-stack files/usr/libexec/arm-xps-flowlimit \
  files/etc/hotplug.d/net/20-rps-xps files/etc/hotplug.d/iface/20-rps-xps \
  files/etc/uci-defaults/9*
```

`actionlint` extracts each `run:` block to a temp dir and so never reads `.shellcheckrc` --
its exclusions must be passed via `SHELLCHECK_OPTS`, and the two lists have to be kept in
sync (see `.github/workflows/lint.yml`).

When a build result looks stale or inexplicable, re-run with the `nocache` input before
debugging anything else: it suffixes the cache keys with the run ID *and* blanks `dl`'s
`restore-keys`, so all three layers genuinely miss. The `ssh` input opens an upterm session
on the runner for interactive debugging.

## Load-bearing constraints

These break things silently and are not visible from the file you are editing:

- **`CONFIG_AUTOREMOVE` is disabled** in `.config`. With it on, a stale build dir triggers
  `host-clean-build`, which runs `Host/Uninstall` (deleting
  `staging_dir/host/bin/autoconf`) but removes only `HOST_BUILD_DIR` and
  `HOST_STAMP_BUILT`; `HOST_STAMP_INSTALLED` lives in `staging_dir/host/stamp/` and
  survives, so autoconf reads as installed with no binary and `tools/libtool`'s
  `./bootstrap` aborts. That asymmetry is real, but the causal link to this repo's failure
  was never reproduced, and the `RELEASE=false` bug below explains every observed sample.
  - TODO (open): to validate, flip `CONFIG_AUTOREMOVE=y` alone and dispatch one build with
    `nocache=true` -- on a cache hit "Skip toolchain rebuild" strips the `tools/` stamp
    deps, `tools/` is never traversed, and the run proves nothing. It gates the only way to
    make the toolchain cache incremental, since caching the host-build stamps needs
    AUTOREMOVE twice over: only under it does `HOST_STAMP_PREPARED` hash content rather
    than path plus mtime (otherwise the stamp filename changes on every fresh CI clone),
    and only its post-compile wipe keeps the zero-length dot stamps that make such a cache
    small.
- **The prebuilt LLVM-BPF tarball must land before the first `make`.** `.config` selects
  `BPF_TOOLCHAIN_PREBUILT`, gated by `HAS_PREBUILT_LLVM_TOOLCHAIN` -- a
  `def_bool $(shell, [ -f llvm-bpf/.llvm-version ] ...)` in `toolchain/Config.in`,
  evaluated when kconfig *parses*, not when a package builds. "Fetch prebuilt LLVM-BPF
  toolchain" therefore runs immediately after "Clone source code", ahead of the
  `make defconfig` in "Download package"; move it later and the symbol reads n, the choice
  silently falls back to `BPF_TOOLCHAIN_BUILD_LLVM`, and the build spends hours compiling
  LLVM. Version and filename shape come from the cloned tree's own
  `tools/llvm-bpf/Makefile`, never hardcoded. Failure is a hard `::error::` rather than a
  fall back to source, because "the build got slow" is the least noticeable failure signal
  there is. Two hosts are tried, since their buildbots publish on different schedules, and
  only under `snapshots/`, so a release branch pinning a different LLVM fails here instead
  of silently building one; during an upstream bump, wait for the publish or temporarily
  set `CONFIG_BPF_TOOLCHAIN_BUILD_LLVM` back.
- **"Build host tools" is gated on the toolchain cache *missing*, and has to be.** "Skip
  toolchain rebuild" strips the tools stamp *dependencies* out of the top-level `Makefile`,
  which stops `make world` rebuilding them but does nothing about a target named on the
  command line -- and that step runs `make tools/install`, so unconditional it would rebuild
  every host tool on a cache hit. On a genuine miss the rebuild is total, because
  `HOST_STAMP_INSTALLED` is in the cached `staging_dir/host/stamp/` while the
  `.prepared`/`.configured`/`.built` it depends on are in the uncached
  `build_dir/host/<pkg>-<ver>/` -- which is why a `restore-keys` fallback on `staging_dir`
  alone buys nothing.
- **Never put a bare `RELEASE`, `VERSION`, `PACKAGE`, or `PREFIX` in the build steps'
  environment.** Autoconf ships a `GNUmakefile` (which GNU make prefers over `Makefile`)
  including gnulib's `maint.mk`, which does
  `ifdef RELEASE: VERSION := $(word 1,$(RELEASE))`; make imports environment variables as
  make variables, so an exported `RELEASE=false` rewrites autoconf's own `$(VERSION)`.
  `tools/autoconf` then builds and installs cleanly but reports
  `autoconf (GNU Autoconf) false`, and gnulib's `bootstrap` in `tools/libtool` fails its
  version check with the misleading `Prerequisite '.../autoconf' not found` -- the same
  visible symptom as the `CONFIG_AUTOREMOVE` bug above. The workflow's release/bindir
  inputs are therefore exported as `DO_RELEASE`/`KEEP_BINDIR`, and both `make` steps
  `unset RELEASE VERSION PACKAGE PREFIX` as a second layer.
- **The kernel config must land in the *subtarget* directory, not the board directory.**
  Kernel configs merge `target/linux/generic` -> `<board>` -> `<board>/<subtarget>`, and
  `scripts/kconfig.pl`'s `+` operator is a plain assignment, so **the last file wins
  unconditionally**: a fragment left at board level is silently overridden for every symbol
  upstream also sets in the subtarget file. "Load custom configuration" therefore moves it
  into `target/linux/$TARGET_BOARD/$TARGET_SUBTARGET/` when that directory exists. Deleting
  a line from the fragment is not a no-op either -- the file *replaces* upstream's subtarget
  config rather than layering onto it, so a removed symbol loses upstream's value, and for a
  prompted symbol nothing else in the chain answers, so non-interactive `syncconfig` stops
  at the question and fails `target/linux` seconds in.
- **The kernel config filename is derived, not hardcoded.** "Resolve build target" reads
  `CONFIG_TARGET_BOARD`/`CONFIG_TARGET_SUBTARGET` from `.config`; "Load custom
  configuration" reads the source tree's actual `KERNEL_PATCHVER` from the target Makefile
  and renames the fragment to `config-$kver`. If upstream's kernel version has drifted from
  the file's own version, the workflow emits an `::warning::` and applies the fragment under
  the *source's* version anyway -- the filename's version is not authoritative once bumped.
  Treat that warning as real work: the fragment is upstream's subtarget config plus
  deliberate deltas, and a kernel bump can delete the symbols those deltas name.
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
- **No `actions/setup-go` step, and none is needed.** `dae` declares
  `PKG_BUILD_DEPENDS:=golang/host bpf-headers` and builds via `golang-package.mk`, so
  OpenWrt bootstraps its own host Go through the normal `tools/` chain. Don't re-add a Go
  setup step without checking whether the package that prompted it actually needs one
  (`grep PKG_BUILD_DEPENDS` its Makefile for `golang/host`).
- **`dl` holds only hash-verified tarballs, and the Go module cache must stay out of it.**
  Upstream puts `GO_MOD_CACHE_DIR` at `$(DL_DIR)/go-mod-cache`, mixing two incompatible
  kinds of state in one cached directory. Everything else in `dl` is an immutable tarball
  checked against `PKG_HASH`, which is what earns `dl` its broad `restore-keys` fallback; a
  Go module cache is an extracted, deliberately writable tree (`-modcacherw`) with no
  integrity check on read, so a partially-populated one surfaces as module-resolution
  errors that point nowhere near the cache -- and `restore-keys` then hands it to every
  later run. `after-installing-feed.sh` repoints it at `$(BUILD_DIR_BASE)/go-mod-cache`,
  alongside the equally regenerable `$(TMP_DIR)/go-build`, and warns if that line no longer
  matches.
- **The whole `openwrt` checkout is a symlink into `/mnt`, not just
  `dl`/`staging_dir`/`build_dir`.** "Clone source code" creates `$BUILD_ROOT`
  (`/mnt/openwrt`), points `$GITHUB_WORKSPACE/openwrt` at it with one `ln -snf`, and clones
  straight into `$BUILD_ROOT`; there is no real `openwrt/` under the workspace at all.
  `/mnt` is a bind-mounted volume declared at the *job* level (`volumes: [/mnt:/mnt]`) --
  a step-level mount would not work.
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
- **The build job tries to bounce itself onto an AMD runner, and self-cancels to do it.**
  After "Set default inputs" it reads `vendor_id` from `/proc/cpuinfo`; on a
  non-`AuthenticAMD` runner it re-dispatches itself as `Retry on AMD` with `attempt+1`
  (forwarding every resolved input through the `client_payload`), cancels the current run
  via the REST API, and exits non-zero. It gives up after 5 attempts, so one dispatch can
  leave up to four cancelled runs behind -- expected output, not failures to debug. The
  loop needs `permissions: actions: write` on the job and `Retry on AMD` in the
  `repository_dispatch` type filter; drop either and a non-AMD runner becomes a hard stop.
  Any new input must also be added to that `client_payload`, or it silently reverts to its
  default on every retry.
- **`after-installing-feed.sh` hardcodes `x86`, and its alignment `sed` is deliberately
  fragile.** That `sed` rewrites `target/linux/x86/image/Makefile` by literal path, unlike
  the workflow, which derives board/subtarget from `.config`; on any other target it
  silently matches nothing. The edit moves alignment from upstream's 256K to 4096K so both
  partitions start on an SSD/eMMC erase-block boundary; the number is passed positionally as
  `gen_image_generic.sh`'s 6th argument and lands at `ptgen -l` (KB). The script requires
  **exactly one** bare `256` line in that Makefile and emits an `::warning::` instead of
  editing when that does not hold. Do not simplify it back to `s/256/4096/g`: any other 256
  upstream later adds would be rewritten too, with no error.
- **`CONFIG_MMCONF_FAM10H` in the kernel fragment cannot be hand-disabled.** It is an
  invisible `def_bool` the kernel Kconfig computes from other flags (`X86_64 &&
  PCI_MMCONFIG && ACPI`, all true regardless of vendor); writing `# ... is not set` is
  silently reverted by `make defconfig`/`syncconfig`. This build is Intel-only, so the line
  is dead weight that cannot be removed, not a misconfiguration.
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
  match. Three interdependent pieces fix it: (1) `after-installing-feed.sh` generates
  `feeds/packages/net/miniupnpd/patches/100-nat-loopback.patch` so `configure` stops
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
- **The job container runs as root; `make` itself must not.** GitHub's JS actions need to
  write to `/__w/_temp` as root, so the container cannot be started with
  `container.options: --user buildbot` -- that breaks checkout with `EACCES`. The container
  stays root, "Set build user permissions" `chown -R`s `$BUILD_ROOT` and `/mnt/buildhome`
  (used as `$HOME`) to `buildbot:buildbot`, and only the actual `make`/`su -m buildbot -c
  '...'` invocations drop privileges. `su -m` is required, not plain `su -c`, or the step's
  `env:` does not survive into the subshell.
- **`CONFIG_BUILD_LOG=y`** writes each package's build output under `openwrt/logs/`, which
  is what makes "Upload build logs" (on compile failure) contain anything -- without it
  that artifact holds only `.config`.
- **A broken rpcd ucode plugin fails silently -- `logread` shows nothing.** ucode resolves
  `import` names at *compile* time, so one missing export makes the whole script fail to
  compile and rpcd skips it without logging, registering no ubus object. Every LuCI call
  against it then returns `-32000 Object not found` (genuinely "not registered"; an ACL
  problem reports `Access denied`). To see the real error, run the plugin by hand:
  `ucode -R /usr/share/rpcd/ucode/<name>`. This bit `luci-app-podman`, which imports
  `init_action` from `luci.sys` -- a name no LuCI tree exports -- so
  `after-installing-feed.sh` defines it locally after the clone. The exposure is structural:
  the package is cloned `--depth=1` from its default branch with no pin, against a LuCI that
  rolls with ImmortalWrt master.
- **A generic "pull and recreate" for podman is not possible here, so `podman-stack update`
  is definition-driven.** `files/usr/bin/podman-stack` supplies the two things podman cannot
  schedule without systemd. `watchdog` runs the health probes -- `--health-interval` uses
  systemd transient timers, so nothing else ever fires them, and without it the health
  column in `podman ps` freezes into a snapshot that reads like live status. `update`
  reimplements `podman auto-update`, which only touches containers carrying the
  `PODMAN_SYSTEMD_UNIT` label a quadlet writes; it must re-`create` each container from a
  spec in `/etc/podman-stack.d/*.conf`, because podman has no primitive that rebuilds a
  container in place on a new image -- `podman container clone` looks like one but silently
  drops `--network=host` and every `--cap-add`, so the rebuilt container cannot start. That
  directory ships empty, so `update` is inert until someone fills it in. Neither subcommand
  touches boot: autostart belongs to the `/etc/init.d/container-<name>` procd services
  luci-app-podman generates.
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

## Factory defaults

Scripts under `files/etc/uci-defaults/` run once per flash in filename order and are then
deleted. Their shared convention is **fill in, never overwrite** (`set_if_unset`, or a
check that the current value is still the factory one), because all of `/etc/config/` is on
sysupgrade's keep list, so after an upgrade the value on the device is authoritative.

- `90-luci-theme` -- corrects `luci.main.mediaurlbase`; this image drops the bootstrap
  theme.
- `91-unbound-odhcpd` -- wires up `maindhcp` / `leasetrigger`; without it the LAN gets no
  DHCPv4, or no hostname resolution.
- `92-flowtable-no-wandev` -- on a PPPoE uplink only, removes the physical port from the
  flowtable (see above).
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

## Workflow conventions

- `build-immortalwrt.yml` serves both `workflow_dispatch` and `repository_dispatch`. Every
  input resolves as `PAYLOAD_x :- INPUT_x :- hardcoded default` in the "Set default inputs"
  step and is passed downstream through `$GITHUB_ENV`. New inputs must follow the same
  three-tier pattern.
- Conditionals compare env vars as strings (`env.ARTIFACT == 'true'`), never as booleans.
  Post-compile steps are guarded with `!cancelled()`.
- `feeds.conf.default` is the default of the `feeds_conf` input but does not exist in this
  repo; the `[ -e ... ] && mv` is intentionally a no-op and `before-installing-feed.sh`
  patches upstream's copy instead.
- Both workflows default their upstream branch to `master`, ImmortalWrt's rolling
  development branch. That default lives in three places that must agree:
  `update-checker.yml`'s `REPO_BRANCH`, and `build-immortalwrt.yml`'s `branch` input
  default *and* its hardcoded fallback in "Set default inputs" (`repository_dispatch` only
  ever reaches the latter). If they drift, the checker watches a branch nobody builds.
  Passing `latest` resolves the newest `openwrt-YY.MM` stable branch dynamically, but only
  `build-immortalwrt.yml` implements that -- `update-checker.yml` does a plain
  `git clone -b`, so `latest` would just fail there.
- Every action is referenced by its upstream **default branch** -- `@main` everywhere
  except `softprops/action-gh-release`, whose default branch is `master`. This is
  deliberate: builds always pick up the newest upstream action code, at the accepted cost
  that builds are not reproducible and an upstream compromise or breaking change lands in
  the very next run with no review step. Don't re-pin to SHAs or tags without asking.
- `GITHUB_TOKEN` is the only secret. `repository-dispatch` works with it only because it
  targets this same repo.

## Guard rails

`.claude/hookify.*.local.md` holds hookify rules and is **checked in**, despite the
`.local` in the name -- hookify globs that exact path relative to the repo root, so a rule
that is not committed only protects the machine that wrote it.

One rule warns on edits touching the OTA version contract, because that failure is
invisible: a wrong timestamp format or asset name builds and ships cleanly, then bricks
updates on routers already in the field.

## Git etiquette

Commit directly to `main`; no PR flow. Subject lines are `area: summary`.
Comments, documentation, and CI diagnostics in this repo are English.
