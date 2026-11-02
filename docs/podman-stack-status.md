# Podman stack maintenance status

Updated 2026-11-02.

`podman-stack watchdog` runs health probes and uses Podman's restart policy and
`StoppedByUser` to recover eligible exited containers. `always` and
`unless-stopped` are recovered when not explicitly stopped; it does not bypass
`on-failure` limits. For an unhealthy container it uses `podman stop --service`,
then starts it; an ID-keyed /var/run marker allows retrying its own failed start.
An explicit stop takes precedence. See `files/etc/podman-stack.d/README` for
concurrency, reboot, and option availability limitations.

`podman-stack update` requires an explicit trusted definition for each managed
container. It retains the original container until the replacement is created
and, if the original was running, started. It attempts rollback on failure and
keeps the prior image under a dedicated tag.
Updates do not undo data-volume changes or verify application readiness. Avoid
concurrent changes via LuCI or other Podman commands. LuCI's container rebuild
only covers a subset of inspect options. Both old and new LuCI init service
prefixes are included in `files/etc/sysupgrade.conf`.

The obsolete upstream `init_action` patch was removed; current upstream uses
ubus. The upstream LuCI package is not pinned, so behavior can change between
firmware builds.

Verification: 12 mock-based tests in `tests/test_podman_stack.py`, ShellCheck,
actionlint and `git diff --check` passed. On the router Podman 5.8.4 accepted
`podman stop --service` on a running networkless Alpine test container and
reported `exited` with `StoppedByUser=false`; a separate manual Samba stop was
observed to set the field to true. Real watchdog restart-failure recovery,
update/rollback and reboot have not been tested on the router. The work has not
been deployed to the router as part of this session.

A first Alpine test on the default Podman network failed because aardvark-dns
could not bind 10.88.0.1:53. The listener and its relationship to other
container failures are not yet established. If investigating, inspect the
listener and network configuration before making changes. The temporary test
container may remain on the router; verify before removing it.
