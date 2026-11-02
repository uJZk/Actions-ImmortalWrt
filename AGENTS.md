# Project guidance

## What this repo is

A config-only GitHub Actions build repo for x86/64 ImmortalWrt firmware (derived from
P3TERX/Actions-OpenWrt). There is **no application source here** -- CI shallow-clones
upstream ImmortalWrt into `openwrt/` and injects this repo's `.config`, `config-6.18`,
`files/`, and the two feed-patch scripts into that tree. Editing anything here changes a
build recipe, not a program.

Both `before-installing-feed.sh` and `after-installing-feed.sh` execute with cwd
`openwrt/`, so their paths are relative to the upstream tree, not to this repo.

`README.md` is the outward-facing summary: what the image contains, how to dispatch a
build, and the repository layout. The linked guidance describes constraints that are not
visible from the file you are editing. Keep package-selection rationale in one place, not both.

## Detailed guidance

Read the relevant notes before changing the build or image; several constraints fail silently:

- [Build constraints](docs/build-constraints.md): toolchain caches, LLVM-BPF ordering,
  kernel configuration, runner and build workflow requirements.
- [Runtime constraints](docs/runtime-constraints.md): OTA, networking, storage, Podman,
  and package interactions.
- [Factory defaults](docs/factory-defaults.md): per-flash behavior and modem access.
- [Build verification](docs/build-verification.md): lint, local workflow execution,
  and cache troubleshooting.

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

## Verification status

For the miniupnpd STUN change, verification status and remaining router tests,
see [docs/upnp-stun-status.md](docs/upnp-stun-status.md).

For miniupnpd internal-client fallbacks, verification status and remaining router
tests, see [docs/upnp-client-fallback-status.md](docs/upnp-client-fallback-status.md).

For Podman watchdog, image update, device verification and remaining work, see
[docs/podman-stack-status.md](docs/podman-stack-status.md).

For the documentation sweep, decisions, and remaining verification, see
[docs/docs-sweep-2026-11-02/README.md](docs/docs-sweep-2026-11-02/README.md).

For the documentation split and its verification, see
[docs/documentation-split-status.md](docs/documentation-split-status.md).
