# ADR-007: Recovery Retention Enforcement

## Status

Accepted; persistence pruning superseded by the 2026-10-01 security hardening below.

## Context

Atlas already documents a retention-window recovery model, including `RecoveryItem.expiresAt`, the `expired` task-state concept, and `restore_expired` in the error-code registry. The shipped worker, however, still restores items solely by presence in `snapshot.recoveryItems`. That means an expired entry can remain visible and restorable if it has not yet been pruned from persisted state.

This creates a trust gap in a release-sensitive area: History and Recovery can claim that items are available only while the retention window remains open, while the implementation still allows restore after expiry.

## Decision

- Atlas must treat expiry as an enforced worker and persistence boundary, not only as UI copy.
- `AtlasWorkspaceRepository` must prune expired `RecoveryItem`s on load and save so stale entries do not remain in active recovery state across launches.
- `AtlasScaffoldWorkerService.restoreItems` must recheck expiry at request time and fail closed before any restore side effect.
- Restore rejections must use stable restore-specific protocol codes for expiry and restore conflicts.
- Presentation may add defensive restore disabling for expired entries, but worker enforcement remains authoritative.

## Consequences

- Recovery behavior now matches the documented retention contract.
- Expired entries stop appearing as active recovery inventory after repository normalization.
- Restore batches remain fail closed: if any selected item is expired, the batch is rejected before mutation.
- Protocol consumers must handle the additional restore-specific rejection codes.

## Alternatives Considered

- Narrow docs to match current behavior: rejected because it preserves an avoidable trust gap.
- Enforce expiry only in the restore command: rejected because stale entries would still persist in active recovery state.
- Fix only in UI: rejected because restore is ultimately a worker-boundary guarantee.

## Security revision — 2026-10-04

Schema 2 retains recovery evidence on both load and save, including expired, failed and unknown operations. Expiry still disables automatic restore in the Worker/UI, but never deletes a journal record or its physical source. The old repository pruning decision above is superseded. History may archive records without claiming that a source was removed or restored. Missing displayed rows are reported as unknown changes, never inferred as expiry.
