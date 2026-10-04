#!/usr/bin/env bats
setup() { export MOLE_TEST_MODE=1; ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }
@test "launchd Program takes precedence over custom argv zero" {
 cat > "$TMP/item.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>/usr/bin/true</string><key>ProgramArguments</key><array><string>custom-argv-zero</string></array></dict></plist>
PLIST
 run bash -c 'source "$1/lib/clean/apps.sh"; classify_launch_item "$2"' _ "$ROOT" "$TMP/item.plist"
 [ "$status" -eq 0 ]; [ "$output" = present ]
}
@test "relative and invalid programs are unknown and no commands mutate services" {
 cat > "$TMP/item.plist" <<'PLIST'
<plist version="1.0"><dict><key>ProgramArguments</key><array><string>relative</string></array></dict></plist>
PLIST
 run bash -c 'source "$1/lib/clean/apps.sh"; launchctl() { return 99; }; safe_remove() { return 99; }; classify_launch_item "$2"' _ "$ROOT" "$TMP/item.plist"
 [ "$status" -eq 0 ]; [ "$output" = unknown ]
}
@test "absolute missing executable is reported but not uninstalled" {
 cat > "$TMP/item.plist" <<'PLIST'
<plist version="1.0"><dict><key>Program</key><string>/nonexistent-atlas-test-executable</string></dict></plist>
PLIST
 run bash -c 'source "$1/lib/clean/apps.sh"; classify_launch_item "$2"; is_launch_item_orphaned "$2" && exit 99; exit 0' _ "$ROOT" "$TMP/item.plist"
 [ "$status" -eq 0 ]; [ "$output" = missing ]
}
