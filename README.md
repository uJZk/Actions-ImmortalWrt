# Actions-ImmortalWrt

[![LICENSE](https://img.shields.io/github/license/uJZk/Actions-ImmortalWrt.svg?style=flat-square&label=LICENSE)](https://github.com/uJZk/Actions-ImmortalWrt/blob/main/LICENSE)
![GitHub Stars](https://img.shields.io/github/stars/uJZk/Actions-ImmortalWrt.svg?style=flat-square&label=Stars&logo=github)
![GitHub Forks](https://img.shields.io/github/forks/uJZk/Actions-ImmortalWrt.svg?style=flat-square&label=Forks&logo=github)

A GitHub Actions build recipe for x86/64 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)
firmware, derived from [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt).

There is no application source in this repository. The workflow shallow-clones
ImmortalWrt into `openwrt/` on the runner and injects this repo's `.config`,
kernel fragment, `files/` overlay, and two feed-patch scripts into that tree.
Editing anything here changes a build recipe, not a program.

The output is a GPT/EFI image with an EROFS root (`*combined-efi.img.gz`) plus a
rootfs tarball. BIOS GRUB, SquashFS and ext4 images are switched off. The target
is a single generic x86_64 profile, compiled with `-march=goldmont-plus` -- that
is one specific box (a J4125 mini PC), not a portable default. This is one
person's build, tuned for a mainland-China home line; treat it as a starting
point to fork, not as a distribution.

## What is in the image, and why

The package selection is opinionated. The main deviations from a stock build:

| Choice | Why |
| --- | --- |
| `unbound` + `odhcpd`, no dnsmasq at all | dnsmasq-full and every sub-option are deselected, and `odhcpd-ipv6only` is swapped for the full `odhcpd` so DHCPv4 still exists. unbound ships a supported odhcpd lease bridge, so LAN hostnames still resolve. Forwarding is fixed to a public resolver rather than recursing or following the ISP. |
| `qosify` (cake) for shaping | Rate limits ship empty and the service ships disabled -- they are per-line and have to be measured on site. Structural parameters (diffserv4, NAT awareness, PPPoE overhead) are pre-set. |
| `dae` via the `daede` feed, with `luci-app-daede` | The feed is pinned ahead of `packages` in `feeds.conf.default` because both ship a package called `dae`, and only the `daede` copy returns `TC_ACT_PIPE` on WAN egress, which is what lets qosify's DSCP marking still run on the same `clsact`. |
| `podman` plus the third-party `luci-app-podman` | The LuCI app is cloned into `package/`, not added as a feed. `files/usr/bin/podman-stack` adds the two things podman cannot schedule without systemd: `watchdog` (runs health probes) and `update` (rebuilds containers from `/etc/podman-stack.d/*.conf`). |
| `miniupnpd-nftables` with NAT loopback | miniupnpd has no hairpin support. `after-installing-feed.sh` patches out the `iif` match on its DNAT rules and adds a guard, and `files/usr/share/nftables.d/` supplies the return-path SNAT. |
| `luci-theme-footstrap`, no bootstrap | Dropping bootstrap needs both a feed patch (it is a hard dependency of `luci-light`) and a uci-default to fix `mediaurlbase`. |
| `f2fsck` + `fstrim` compiled in | The deployed router carries a separate f2fs data partition for podman's graphroot. This repo does not create that partition, but the image has to supply the two binaries, since neither is a busybox applet here and an apk-installed copy would not survive sysupgrade. |
| Software flow offload on, hardware off | The NICs have no hardware flowtable. On a PPPoE uplink a uci-default trims the physical WAN device out of the flowtable, so ingress shaping and offload can coexist. |
| `nlbwmon` deselected | Offloaded flows stop updating conntrack counters, so its per-host totals would be arbitrarily low. |
| OTA via `easyupdate.sh` | `/usr/bin/easyupdate.sh -c` checks the newest GitHub release, `-u` downloads, sha256-verifies and flashes it. Release assets are fetched via github.com first and a list of mirrors as fallback. A commented weekly cron entry is shipped in `/etc/crontabs/root`. |

`files/etc/uci-defaults/` also lands timezone/NTP, the LAN domain, packet
steering, fullcone NAT, UPnP parameters and an apk mirror. Those scripts only
fill in missing values -- `/etc/config/` is on sysupgrade's keep list, so what is
already on the device wins.

## Building it

1. Fork this repository.
2. Adjust `.config` (packages, partition sizes, `CONFIG_TARGET_OPTIMIZATION`),
   `config-6.18` (kernel symbols), and `files/` (the rootfs overlay).
3. Run the **Build ImmortalWrt** workflow from the Actions tab.

Inputs worth knowing:

| Input | Default | Notes |
| --- | --- | --- |
| `branch` | `master` | ImmortalWrt's rolling branch. `latest` resolves the newest `openwrt-YY.MM` stable branch instead. |
| `nocache` | `false` | Suffixes all cache keys with the run id and blanks the `dl` fallback, so toolchain/ccache/dl genuinely miss. Try this first when a result looks stale. |
| `ssh` | `false` | Opens an upterm session on the runner for interactive debugging. |
| `release` | `false` | Publishes the images as a GitHub release. The OTA updater reads releases, so this is what makes updates available to flashed devices. |
| `artifact` | `true` | Uploads the firmware directory as a workflow artifact. |
| `bindir` | `false` | Uploads the whole `bin/` tree plus packaged kmod/package archives. |
| `repo`, `name`, `config`, `kernel_config`, `feeds_conf` | -- | Point the build at a different source tree or a different set of config files. |

A build takes roughly an hour on a warm cache. The job asks for an AMD runner: on
a non-AMD one it re-dispatches itself and cancels the current run, up to five
times, so a single manual dispatch can leave cancelled runs behind. That is
expected. `update-checker.yml` watches the upstream branch and dispatches a build
when it moves; `lint.yml` runs `actionlint` and `shellcheck`.

## Repository layout

| Path | Feeds into |
| --- | --- |
| `.github/workflows/build-immortalwrt.yml` | The build itself: clone, cache, patch, `make`, publish. |
| `.github/workflows/update-checker.yml` | Watches upstream and dispatches a build on new commits. |
| `.github/workflows/lint.yml` | actionlint + shellcheck on this repo. |
| `.config` | The full OpenWrt build config: target, image format, package selection. |
| `config-6.18` | Kernel fragment. Copied into the *subtarget* directory and renamed to the source tree's actual kernel version -- it replaces upstream's subtarget config rather than layering onto it. |
| `files/` | Copied into the image as-is: uci-defaults, sysctl, hotplug scripts, nftables snippets, `easyupdate.sh`, `podman-stack`. |
| `before-installing-feed.sh` | Runs in the cloned tree before `feeds update`: edits `feeds.conf.default`. |
| `after-installing-feed.sh` | Runs after `feeds install`: patches feed Makefiles (luci-light theme dep, Go module cache path, miniupnpd NAT loopback, image partition alignment) and clones `luci-app-podman`. |
| `CLAUDE.md` | The long-form notes: every non-obvious constraint that this build depends on. |

Both feed scripts run with `openwrt/` as their working directory, so their paths
are relative to the upstream tree, not to this repo.

## After flashing

- **podman storage is not configured by this repo.** `/etc/containers/storage.conf`,
  `containers.conf` and the network definition have to be written by hand, and
  the graphroot pointed at persistent non-rootfs storage before pulling any
  image -- the rootfs partition is small. If you put it on a mounted data disk,
  read the note in `CLAUDE.md` about rc.d ordering first: podman starts before
  the mount is ready and fails in ways that look like nothing is wrong.
- **Bandwidth values are per-line.** qosify ships disabled with no rate set, and
  the speed UPnP advertises is likewise left empty. Measure the line, then fill
  them in.
- **`/etc/podman-stack.d/` ships empty** (README only), so `podman-stack update`
  does nothing until container definitions are written there. `watchdog` needs no
  definitions and works on any running container that has a health probe.
- Other deliberate non-defaults: ULA, SSH port and auth, whether UPnP is enabled,
  dae's node configuration, any `/mnt` mount, and bypass access to an ONT's
  management page on a PPPoE uplink (that last one has a worked example in
  `CLAUDE.md`).

## Before changing anything

Read [`CLAUDE.md`](CLAUDE.md). It documents the constraints that are not visible
from the file you would be editing -- toolchain caching, the prebuilt LLVM-BPF
fetch ordering, why the kernel fragment must land in the subtarget directory, the
OTA version contract with routers already in the field, and the interactions
between flow offload, qosify and dae. Several of them fail silently.

## Credits

- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)
- [GitHub Actions](https://github.com/features/actions)
- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)
- [sundaqiang/openwrt-packages](https://github.com/sundaqiang/openwrt-packages/tree/master/luci-app-easyupdate)
- [kenzok8/openwrt-daede](https://github.com/kenzok8/openwrt-daede)
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release)
- [owenthereal/action-upterm](https://github.com/owenthereal/action-upterm)
- [peter-evans/repository-dispatch](https://github.com/peter-evans/repository-dispatch)
- [ophub/delete-releases-workflows](https://github.com/ophub/delete-releases-workflows)


## License

[MIT](https://github.com/uJZk/Actions-ImmortalWrt/blob/main/LICENSE) © [**uJZk**](https://github.com/uJZk)
