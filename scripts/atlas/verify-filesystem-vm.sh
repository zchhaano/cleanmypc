#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != "--execute" ]]; then
    printf '%s\n' 'Filesystem VM checklist: disposable snapshot; both architectures; case-sensitive and ordinary APFS; mounted subtree; ancestor replacement; installer asset checks; restore original snapshot.'
    exit 0
fi
marker=/var/db/atlas-disposable-vm
[[ -f "$marker" && ! -L "$marker" && "$(stat -f '%u:%Lp' "$marker")" == '0:600' ]] || { echo 'VM marker absent or untrusted' >&2; exit 1; }
[[ -n "${ATLAS_VM_SNAPSHOT_ID:-}" ]] || exit 1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
go test -race ./internal/safefile ./cmd/safe-remove
./scripts/atlas/security-regression.sh --component all
echo 'Record mounted filesystem checks separately; this script does not create or detach disks.'
