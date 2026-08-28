---
name: warn-ota-version-contract
enabled: true
event: file
action: warn
conditions:
  - field: new_text
    operator: regex_match
    pattern: DISTRIB_VERSIONS|BUILD_TIME=|lFirVer|cFirVer|combined-efi\.img\.gz
---

**You are editing the OTA version contract.**

`DISTRIB_VERSIONS` is a runtime contract with routers already in the field.
`.github/workflows/build-immortalwrt.yml` writes `<12-digit timestamp>_<short
sha>` into `/etc/openwrt_release`; `files/usr/bin/easyupdate.sh` parses those 12
digits back out. Producer and consumer live in different files and nothing
checks that they agree.

**Before changing this, confirm:**

- The timestamp still comes from `date +"%Y%m%d%H%M"` -- exactly 12 digits, no
  separators. `easyupdate.sh` matches `[0-9]\{12\}` and slices fixed offsets.
- The `_<short sha>` suffix is preserved: the sed regex tolerates trailing
  content but not a changed digit run.
- Release asset names still match what `easyupdate.sh` downloads: it picks
  `combined-efi.img.gz` vs `combined.img.gz`, derives the filename from the
  URL's basename, fetches `sha256sums` by substituting that basename, and
  reverse-parses `DISTRIB_GITHUB` by fixed field index for the API URL.

**A wrong change here does not fail the build.** It ships, and every deployed
router silently stops updating, with no way to push a fix except by hand.

If this edit does not touch the version format or asset naming, ignore this.
