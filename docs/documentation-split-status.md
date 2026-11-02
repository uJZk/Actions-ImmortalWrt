# Documentation split status

The project guidance was split from `AGENTS.md` into build constraints, runtime
constraints, factory defaults, and build verification under `docs/`. `AGENTS.md`
retains the project rules and an index; README and source comments point to the
relevant notes.

The split preserved all 35 original constraints and the verification instructions.
Local Markdown links and `git diff --check` passed. This documentation and comment
change did not require a firmware build.

The remaining STUN and Podman router checks are tracked in
[upnp-stun-status.md](upnp-stun-status.md) and
[podman-stack-status.md](podman-stack-status.md). Consult the relevant constraint
notes before changing the build or image.
