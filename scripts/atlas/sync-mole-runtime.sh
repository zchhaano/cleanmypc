#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:---check}"
shift || true
if [[ "${1:-}" == "--root" && $# -eq 2 ]]; then ROOT_DIR="$2"; shift 2; fi
[[ $# -eq 0 && ( "$MODE" == "--check" || "$MODE" == "--write" ) ]] || exit 2
python3 - "$ROOT_DIR" "$MODE" <<'PY'
from pathlib import Path
import shutil,sys
root=Path(sys.argv[1]);mode=sys.argv[2]
manifest=root/'scripts/atlas/mole-runtime-files.txt'
bundle=root/'Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/Resources/MoleRuntime'
if not manifest.is_file() or not bundle.is_dir():sys.exit(2)
paths=[p for p in manifest.read_text().splitlines() if p and not p.startswith('#')]
if len(paths)!=len(set(paths)) or any(Path(p).is_absolute() or '..' in Path(p).parts or not p.startswith(('bin/','lib/')) for p in paths):sys.exit(2)
actual={str(p.relative_to(bundle)) for p in bundle.rglob('*') if p.is_file() or p.is_symlink()}
extra=actual-set(paths)
if extra:
 print('Unlisted runtime files: '+', '.join(sorted(extra)),file=sys.stderr);sys.exit(1)
failed=False
for p in paths:
 src=root/p;dst=bundle/p
 if src.is_symlink() or not src.is_file() or dst.is_symlink():
  print('Invalid runtime member: '+p,file=sys.stderr);failed=True;continue
 if mode=='--write':
  dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
 if not dst.is_file() or src.read_bytes()!=dst.read_bytes():
  print('Runtime drift: '+p,file=sys.stderr);failed=True
sys.exit(1 if failed else 0)
PY
