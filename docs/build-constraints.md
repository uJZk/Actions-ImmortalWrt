# Build constraints

These constraints can fail silently; check them when changing the build recipe.

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
  set `CONFIG_BPF_TOOLCHAIN_BUILD_LLVM` back. The Debian stable-slim job
  container supplies the host runtime; the fetch step checks both `clang
  --version` and a BPF compilation before any expensive build. The stable tag
  moves between releases, so host toolchain cache keys include the actual OS,
  libc, libstdc++ and compiler package versions.

- **VHDX images require host `qemu-img`.** The slim job container installs
  `qemu-utils` and checks `qemu-img` before building; the target firmware's
  optional `CONFIG_PACKAGE_qemu-img` is unrelated. Without the host tool,
  image generation fails after compilation.

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
