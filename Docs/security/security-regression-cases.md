# Security regression inventory

`./scripts/atlas/security-regression.sh --component all` requires real nonzero case counts in each component. It runs no sudo, system mutation or installation. Runtime byte/set parity and shellcheck precede Shell tests; the crash harness is built before Swift tests. Logs are retained in a private temporary directory printed by the gate.

| Component | Required suites | What is asserted |
|---|---|---|
| Shell | security_cli, mole_runtime_sync, pam_transaction, launch_item_safety, safe_remove_backend | dangerous execution paths closed; owned scratch identity; byte/set parity; isolated PAM metadata/rollback; launchd three-state reporting; local backend asset/checksum |
| Swift | FileSafety, plan registry, authorization, partial mutation, persistence faults, operation journal, coordinator, recovery crash/executor, workspace corruption | packages/roots/links/identity/conflicts; exact selection/limits; no replay; durable facts and private files; four real child crash windows; damaged state preserved |
| Swift runtime | ProcessRunner, XPCTransport/Completion, HelperClient, organizer scanner, smart-clean scope | bounded pipes/deadlines/cancellation; one completion; read-only retry allowlist; proof matching; package scan filtering and overflow |
| Go race | internal/safefile, cmd/safe-remove | relative cache scope, no-follow descriptors, mounted/special objects, identity replacement, partial cancellation, request limits and exit codes |

The Swift parser requires an actual passed case in **every** named critical class; each Go package must contain passed assertions. Exit zero, unsupported output, a skipped assertion, or a missing class/package is insufficient. Selftest mutates temporary copies only: success, runtime drift, failed test, missing Bats, zero Swift, absent Swift class, skipped Swift assertion, lowercase TAP skip, zero Go package and preceding-component failure.

Separately required: full Apps/Packages/Helper suites, Swift 6 Helper build, Xcode Release build, nonzero real XCUITest, copy/media gates and VM/install/signing acceptance. The security subset cannot substitute for those. Real PAM and mounted-volume/OS evidence are **not** established by mock or isolated-directory tests. No capability is reopened by this gate alone.
