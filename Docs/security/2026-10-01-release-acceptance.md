# Closed-capability candidate acceptance — 2026-10-04

Base `3716c48602a57d24ac2875989ad1beed53ee2405`; branch `security/hardening-2026-10-01`. Implementation commits: `26aa087`, `1ba5044`, `cb9cfe1`, `a632cb6`, `2707776`, `5c83c8c`, `1bbffcc`, plus the final acceptance commit on this branch. Exact candidate is identified by the branch's final commit; do not reopen capabilities using results from an earlier closed commit.

Decision: local code/isolated/real-UI acceptance passes for the **closed candidate**. No release publication or full system-level acceptance is claimed. Native file mutation/PAM/general CLI deletion remain closed. [Detailed commands, counts and logs](2026-10-01-hardening-evidence.md).

| Finding | Verified mitigation | Real-system/reopening status |
|---|---|---|
| SEC-01 PAM | Execution-side closure; isolated transaction/metadata/rollback tests | CLOSED; real root:wheel/0444, sudo authentication and VM rollback NOT RUN |
| SEC-02 deletion boundary | Closed Shell wrapper; descriptor backend, credentials, identity/race/special-object tests; two CLI architectures built | General deletion CLOSED; mounted-subtree and Intel installation NOT RUN |
| SEC-03 package interiors | Scanner and direct policy tests; case-variant protected roots, package ancestors, conflicts and substitution refused | Native mutations CLOSED |
| SEC-04 lost recovery | Durable planned/moved journal, partial batch, persistence faults, four child-crash windows; lease/CAS publication | Native mutations CLOSED; VM disk-full/crash/restart still required |
| SEC-05 update staging | System cleanup and tool bypasses refuse before any update directory mutation | CLOSED; real updating-OS VM NOT RUN |
| SEC-06 service deletion | Program priority; three states; no delete/unload in any state | Automatic service deletion CLOSED |
| SEC-07 network/Bluetooth | Direct functions and optimize dispatch refuse, including failed detection | Automatic resets CLOSED; live-route/BT VM NOT RUN |
| SEC-08 Trash emptying | Normal cleanup cannot empty Finder Trash | CLOSED; explicit analyzer Trash remains separate, unjournaled |
| SEC-09 waits/timeouts | Process output/input/cancellation/TERM/held pipe cases; XPC no-reply/completion/config cases | Escaped process groups and uninterruptible kernel states outside guarantee |
| SEC-10 false restore | Same-name replacement/conflict/unknown/typed request/frozen batch tests; 13 actual UI cases | Native restore CLOSED; legacy mappings unverified |
| SEC-11 UInt16 crash | 65,536 accepted, 100,001 refused; byte and mutation limits | Verified in isolated tests |

Local artifacts: ZIP, DMG, PKG and checksums generated; bundle Helper/XPC/plists/ad-hoc signature integrity verified. CLI arm64/amd64 binaries and backend checksums built. App is arm64+x86_64; this host's packaged Helper is arm64, so do not infer Intel native acceptance. PKG unsigned; Developer ID/notarization and Gatekeeper distribution acceptance NOT RUN. Artifacts stay ignored under `dist/native` and `bin`.

Pending R4: disposable macOS 14/current macOS snapshots, actual available architecture runtime/install checks, PAM recovery administrator session, real mounts, Direct/XPC end-to-end candidate tests, DMG/PKG installation and installed-app launch, signed/notarized candidate, full-acceptance in VM, and new workflow run URLs. `full-acceptance.sh` was not run on the daily host because it modifies `/Applications`. Default VM checklist scripts do not count as execution. No `ATLAS_ALLOW_UI_SKIP=1` was used locally.

Reopening rule: obtain the pending evidence for the same candidate commit, change only the relevant capability, rerun its security subset plus native/install/UI gates, and retain journal/backup evidence. Do not use mock, ad-hoc packaging or closure-state tests as evidence of safe enabled behavior. Roll back to refusal, never to the prior permissive delete/PAM implementation. No push, merge, signed release or publication authorized/performed.
