#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }
@test "cache writes remain closed even with executable backend installed" {
 run bash -c 'source "$1/lib/core/common.sh"; safe_remove "$HOME/Library/Caches/atlas-not-a-real-candidate" false' _ "$ROOT"
 [ "$status" -ne 0 ]
}
@test "installer validates only local cache assets and rejects a corrupt checksum" {
 awk '/^install_safe_remove_backend\(\)/ { printing=1 } printing {print} printing && /^}/ {exit}' "$ROOT/install.sh" > "$TMP/functions.sh"
 run bash -c '
 source "$1/functions.sh"
 SOURCE_DIR="$1/source"; CONFIG_DIR="$1/config"
 mkdir -p "$SOURCE_DIR/bin" "$CONFIG_DIR/bin"
 maybe_sudo() { "$@"; }; log_error() { :; }; log_info() { :; }
 arch=arm64; [[ "$(uname -m)" == arm64 ]] || arch=amd64
 asset="$SOURCE_DIR/bin/safe-remove-darwin-$arch"
 printf "#!/bin/bash\nexit 0\n" > "$asset"
 shasum -a 256 "$asset" > "$asset.sha256"
 install_safe_remove_backend || exit 90
 [[ -x "$CONFIG_DIR/bin/safe-remove-go" ]] || exit 91
 printf "corrupt" >> "$asset"
 install_safe_remove_backend && exit 92
 [[ "$(cat "$CONFIG_DIR/bin/safe-remove-go")" == "#!/bin/bash"* ]] || exit 93
 exit 0' _ "$TMP"
 [ "$status" -eq 0 ]
}
