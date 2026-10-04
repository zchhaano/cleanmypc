#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-optimize.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "needs_permissions_repair returns true when home not writable" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" USER="tester" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
stat() { echo "root"; }
export -f stat
if needs_permissions_repair; then
    echo "needs"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"needs"* ]]
}

@test "has_bluetooth_hid_connected detects HID" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
system_profiler() {
    cat << 'OUT'
Bluetooth:
  Apple Magic Mouse:
    Connected: Yes
    Type: Mouse
OUT
}
export -f system_profiler
if has_bluetooth_hid_connected; then
    echo "hid"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"hid"* ]]
}

@test "is_ac_power detects AC power" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
pmset() { echo "AC Power"; }
export -f pmset
if is_ac_power; then
    echo "ac"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"ac"* ]]
}

@test "is_memory_pressure_high detects warning" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
memory_pressure() { echo "warning"; }
export -f memory_pressure
if is_memory_pressure_high; then
    echo "high"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"high"* ]]
}

@test "opt_system_maintenance reports DNS and Spotlight (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; MOLE_DRY_RUN=1; opt_system_maintenance'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "opt_network_optimization refreshes DNS (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; MOLE_DRY_RUN=1; opt_network_optimization'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "opt_sqlite_vacuum reports sqlite3 unavailable (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; MOLE_DRY_RUN=1; opt_sqlite_vacuum'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "opt_font_cache_rebuild succeeds in dry-run (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; MOLE_DRY_RUN=1; opt_font_cache_rebuild'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "opt_dock_refresh clears cache files (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; MOLE_DRY_RUN=1; opt_dock_refresh'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "execute_optimization dispatches actions" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_dock_refresh() { echo "dock"; }
execute_optimization dock_refresh
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"dock"* ]]
}

@test "execute_optimization rejects unknown action" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization unknown_action
EOF

    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown action"* ]]
}

@test "opt_launch_services_rebuild handles missing lsregister without exiting (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; MOLE_DRY_RUN=1; opt_launch_services_rebuild'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}
