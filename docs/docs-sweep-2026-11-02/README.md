# Documentation sweep 2026-11-02

- Status: complete
- Scope: all tracked documentation; no earlier sweep was found in the checkout or its history.
- Base-commit: 5e2d25e773f85f18af8c90334837423ac1c4214f
- Remote synchronization: fast-forwarded to origin/main before completing the sweep.
- The base commit identifies the reviewed code, not the commit containing this sweep.
- Decisions: consolidated Claude guidance in `AGENTS.md`; corrected documentation against the synced implementation.
- Validation: `git diff --check`; 12 Podman mock tests passed.
- Next steps: perform the STUN router checks and Podman recovery, rollback, and reboot checks described in their status files.
