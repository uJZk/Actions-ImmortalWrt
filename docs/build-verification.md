# Build verification


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

