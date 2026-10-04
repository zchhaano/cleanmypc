#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "${1:-}" != "--execute" ]]; then
    printf '%s\n' 'PAM VM checklist: disposable snapshot; independent administrator recovery session; stock sudo include; preserve main sudo SHA; root:wheel 0444 sudo_local; next sudo authentication; rollback snapshot.'
    exit 0
fi
marker=/var/db/atlas-disposable-vm
[[ -f "$marker" && ! -L "$marker" && "$(stat -f '%u:%Lp' "$marker")" == '0:600' ]] || { echo 'VM marker absent or untrusted' >&2; exit 1; }
[[ -n "${ATLAS_VM_SNAPSHOT_ID:-}" ]] || { echo 'Snapshot ID is required' >&2; exit 1; }
# Only explicitly requested inside a disposable VM. Production touchid/autofix remains closed.
before=$(shasum -a 256 /etc/pam.d/sudo)
sudo /usr/bin/python3 "$ROOT/lib/manage/pam_transaction.py" --vm-acceptance enable
[[ "$(stat -f '%Su:%Sg:%Lp' /etc/pam.d/sudo_local)" == 'root:wheel:444' ]]
sudo -k
sudo -v
sudo /usr/bin/python3 "$ROOT/lib/manage/pam_transaction.py" --vm-acceptance enable
sudo /usr/bin/python3 "$ROOT/lib/manage/pam_transaction.py" --vm-acceptance disable
[[ "$(shasum -a 256 /etc/pam.d/sudo)" == "$before" ]]
echo 'VM PAM smoke completed; perform fault injection and snapshot rollback before acceptance.'
