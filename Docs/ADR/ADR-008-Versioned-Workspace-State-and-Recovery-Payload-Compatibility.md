# ADR-008: Versioned Workspace State and Recovery Payload Compatibility

## Status

Accepted

## Context

Atlas persists a local workspace-state file and stores recovery payloads for both `Finding` and app uninstall flows. Those payloads have already evolved in place: app recovery entries gained uninstall evidence, and the active roadmap now explicitly calls for payload stability, older-state compatibility, and more trustworthy history behavior.

Without an explicit persistence envelope, Atlas can only rely on best-effort shape decoding. That makes future recovery hardening riskier and leaves migration implicit. The `Apps` flow also risks showing stale preview or stale footprint counts after restore unless restored app payloads are reconciled with fresh app inventory.

## Decision

- Atlas persists workspace state inside a versioned JSON envelope containing `schemaVersion`, `savedAt`, `snapshot`, `currentPlan`, and `settings`.
- Atlas continues to decode legacy top-level `AtlasWorkspaceState` files and rewrites them into the current envelope after a successful load when possible.
- `AppRecoveryPayload` carries an explicit `schemaVersion` and remains backward-compatible with the older raw-`AppFootprint` recovery payload shape.
- App restore flows clear stale uninstall preview state and refresh app inventory before the `Apps` surface reuses footprint counts.
- After app restore, `Apps` surfaces the refresh outcome explicitly so Atlas does not silently reuse stale leftover evidence.

## Consequences

- Atlas now has an explicit persistence contract for future migration work instead of relying on implicit shape matching alone.
- Older state files remain loadable while the repo transitions to the versioned envelope.
- App recovery payloads become safer to evolve because compatibility is now a stated requirement.
- The `Apps` surface becomes more trustworthy after restore because it no longer depends only on stale pre-uninstall preview state.
- Post-restore app evidence now has an explicit UI outcome: refreshed or stale, instead of an implicit silent fallback.

## Alternatives Considered

- Keep the unversioned top-level state file and rely on ad hoc per-type decoding: rejected because it scales poorly as recovery payloads evolve.
- Break compatibility and require a fresh state file: rejected because it damages trust in `History` and `Recovery`.
- Refresh app inventory only on explicit user action after restore: rejected because it leaves a visible stale-evidence gap in a trust-critical workflow.

## Security revision — 2026-10-04

Workspace/recovery payload schema is now 2; journal version is 1. An ordinary-user, no-follow private directory (0700), regular single-link files (0600), and a nonblocking cross-process lease protect migration and mutation. Schema 1/raw legacy state is backed up before migration. Corrupt/future state is preserved and causes a visible read-only failure, never replaced with fixtures. Production absence initializes an empty workspace.

Per-file planned/moved/restorePlanned/restored records are the durable authority. Frames include sequence, version and checksum and are fsynced; plan and request selection precede mutations. Damaged journals refuse append/replay; valid prefixes can be shown only as needing reconciliation. Snapshots are rebuildable projections; snapshot save failure retains confirmed facts and freezes further writes. Finder Trash and journaling are separate operations: their unknown interval never authorizes retry or same-name recovery. Older mappings lacking immutable identity remain unverified.
