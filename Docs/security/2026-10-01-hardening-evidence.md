# Security hardening evidence — 2026-10-01

Base: `3716c48602a57d24ac2875989ad1beed53ee2405`.
Workspace: `.worktrees/security-hardening`, branch `security/hardening-2026-10-01`.

## Environment and baseline

macOS 26.6.2 arm64; Xcode 27.0; Swift 6.4 compiler; Go 1.25.0 installed in ignored local tooling using official SHA-256; Bats 1.12.0 in local tooling.
Baseline Packages fails existing `AtlasDesignSystemTests.testAllColorsetTokensResolve` and AtlasFeaturesAppsTests; details in `.superpowers/logs/baseline-packages.log`. Baseline CLI subset passes 46 tests.

## C1

Security regressions observed RED for ancestor-link deletion, sudo removal, failed network/Bluetooth detection, Trash emptying, PAM autofix and service cleanup; temporary-object replacement also RED. Logs: `.superpowers/logs/C1-*-red.log`.
High-risk CLI operations are disabled at execution functions, independent of old configuration and interactive confirmation. Non-cache deletion stays unavailable. Runtime resources synchronize from the explicit manifest; check mode performs no writes. No real PAM/system/network/Trash action was performed.

### Mutation inventory

- `lib/core/file_ops.sh`: data removal delegates only to the confined backend; sudo and symlink removal disabled.
- `lib/clean/system.sh`, service functions in `lib/clean/apps.sh`: read-only safety skip; no system updates or service state changes.
- `lib/clean/user.sh`: Finder Trash operations removed; `.DS_Store` removal routed through safety wrapper.
- `lib/uninstall/batch.sh`: stopping/unloading/deleting services, unregistering apps and real CLI uninstall disabled before side effects.
- `lib/core/base.sh`: cleanup limited to process workspace and registered inode identity; replaced objects preserved.
- Remaining `rm -f` callers in bin/lib are scanner scratch, UI spinner/lock artifacts or Mole's own metadata cache; no generic data cleanup bypass found.
- `cmd/analyze/delete.go`: explicit user-selected Finder Trash action, not permanent `rm`; `cmd/analyze/cache.go`: analyzer's own cache file. Not expanded into a root capability.

## Acceptance pending

VM PAM/real mount, UI, CI run and release installation evidence are pending. Capabilities requiring these remain closed until verified.

C1 GREEN: 140 Bats cases, 0 failures (one legacy analyze-binary availability skip); all 14 new safety/parity cases executed. shellcheck and runtime parity passed. Obsolete positive tests for removed destructive capabilities were replaced by execution-side safety regressions; container tests now assert preservation instead of deletion.

Ruling: existing autofix suggestion test expected a low-disk message deliberately suppressed when a large-cache suggestion exists; corrected it to assert the actual cache suggestion, without changing production behavior.
