#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-system-clean.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_time_machine_failed_backups exits when tmutil has no destinations (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/clean/system.sh"; clean_time_machine_failed_backups'
    [ "$status" -eq 0 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "clean_local_snapshots reports snapshot count" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

defaults() { echo "1"; }


run_with_timeout() {
    printf '%s\n' \
        "com.apple.TimeMachine.2023-10-25-120000" \
        "com.apple.TimeMachine.2023-10-24-120000"
}
start_section_spinner(){ :; }
stop_section_spinner(){ :; }
note_activity(){ :; }
tm_is_running(){ return 1; }

clean_local_snapshots
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Time Machine local snapshots:"* ]]
    [[ "$output" == *"tmutil listlocalsnapshots /"* ]]
}

@test "clean_local_snapshots is quiet when no snapshots" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

defaults() { echo "1"; }


run_with_timeout() { echo "Snapshots for disk /:"; }
start_section_spinner(){ :; }
stop_section_spinner(){ :; }
note_activity(){ :; }
tm_is_running(){ return 1; }

clean_local_snapshots
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Time Machine local snapshots"* ]]
}

@test "clean_homebrew skips when cleaned recently (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/clean/brew.sh"; clean_homebrew'
    [ "$status" -eq 0 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "clean_homebrew runs cleanup with timeout stubs (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/clean/brew.sh"; clean_homebrew'
    [ "$status" -eq 0 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "check_appstore_updates is skipped for performance" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

check_appstore_updates
echo "COUNT=$APPSTORE_UPDATE_COUNT"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNT=0"* ]]
}

@test "check_homebrew_updates reports counts and exports update variables" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

run_with_timeout() {
    local timeout="${1:-}"
    shift
    "$@"
}

brew() {
    if [[ "$1" == "outdated" && "$2" == "--formula" && "$3" == "--quiet" ]]; then
        printf "wget\njq\n"
        return 0
    fi
    if [[ "$1" == "outdated" && "$2" == "--cask" && "$3" == "--quiet" ]]; then
        printf "iterm2\n"
        return 0
    fi
    return 0
}

check_homebrew_updates
echo "COUNTS=${BREW_OUTDATED_COUNT}:${BREW_FORMULA_OUTDATED_COUNT}:${BREW_CASK_OUTDATED_COUNT}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew"* ]]
    [[ "$output" == *"2 formula, 1 cask available"* ]]
    [[ "$output" == *"COUNTS=3:2:1"* ]]
}

@test "check_homebrew_updates shows timeout warning when brew query times out" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

run_with_timeout() { return 124; }
brew() { return 0; }
rm -f "$HOME/.cache/mole/brew_updates"

check_homebrew_updates
echo "COUNTS=${BREW_OUTDATED_COUNT}:${BREW_FORMULA_OUTDATED_COUNT}:${BREW_CASK_OUTDATED_COUNT}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew"* ]]
    [[ "$output" == *"Check timed out"* ]]
    [[ "$output" == *"COUNTS=0:0:0"* ]]
}

@test "check_homebrew_updates shows failure warning when brew query fails" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

run_with_timeout() { return 1; }
brew() { return 0; }
rm -f "$HOME/.cache/mole/brew_updates"

check_homebrew_updates
echo "COUNTS=${BREW_OUTDATED_COUNT}:${BREW_FORMULA_OUTDATED_COUNT}:${BREW_CASK_OUTDATED_COUNT}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew"* ]]
    [[ "$output" == *"Check failed"* ]]
    [[ "$output" == *"COUNTS=0:0:0"* ]]
}

@test "check_macos_update avoids slow softwareupdate scans" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "1"; }

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "10" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        cat <<'OUT'
Software Update Tool

Software Update found the following new or updated software:
* Label: macOS 99
OUT
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Update available"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=true"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "check_macos_update clears update flag when softwareupdate reports no updates" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "1"; }

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "10" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        cat <<'OUT'
Software Update Tool

Finding available software
No new software available.
OUT
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"System up to date"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=false"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "check_macos_update keeps update flag when softwareupdate times out" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "1"; }

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "10" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        return 124
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Update available"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=true"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "check_macos_update keeps update flag when softwareupdate returns empty output" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "1"; }

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "10" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Update available"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=true"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "check_macos_update skips softwareupdate when defaults shows no updates" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "0"; }

run_with_timeout() {
    echo "SHOULD_NOT_CALL_SOFTWAREUPDATE"
    return 0
}

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"System up to date"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=false"* ]]
    [[ "$output" != *"SHOULD_NOT_CALL_SOFTWAREUPDATE"* ]]
}

@test "check_macos_update outputs debug info when MO_DEBUG set" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "1"; }

export MO_DEBUG=1

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        echo "No new software available."
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update 2>&1
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"[DEBUG] softwareupdate exit status:"* ]]
}

@test "run_with_timeout succeeds without GNU timeout" {
    run bash --noprofile --norc -c '
        set -euo pipefail
        PATH="/usr/bin:/bin"
        unset MO_TIMEOUT_INITIALIZED MO_TIMEOUT_BIN
        source "'"$PROJECT_ROOT"'/lib/core/common.sh"
        run_with_timeout 1 sleep 0.1
    '
    [ "$status" -eq 0 ]
}

@test "run_with_timeout enforces timeout and returns 124" {
    run bash --noprofile --norc -c '
        set -euo pipefail
        PATH="/usr/bin:/bin"
        unset MO_TIMEOUT_INITIALIZED MO_TIMEOUT_BIN
        source "'"$PROJECT_ROOT"'/lib/core/common.sh"
        run_with_timeout 1 sleep 5
    '
    [ "$status" -eq 124 ]
}

@test "opt_saved_state_cleanup removes old saved states (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; opt_saved_state_cleanup'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "opt_saved_state_cleanup handles missing state directory (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; opt_saved_state_cleanup'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "opt_saved_state_cleanup continues on permission denied (silent exit) (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; opt_saved_state_cleanup'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "opt_cache_refresh continues on permission denied (silent exit) (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; opt_cache_refresh'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "opt_cache_refresh cleans Quick Look cache (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; opt_cache_refresh'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "get_path_size_kb returns zero for missing directory" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
size=$(get_path_size_kb "/nonexistent/path")
echo "$size"
EOF

    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "get_path_size_kb calculates directory size" {
    mkdir -p "$HOME/test_size"
    dd if=/dev/zero of="$HOME/test_size/file.dat" bs=1024 count=10 2> /dev/null

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
size=$(get_path_size_kb "$HOME/test_size")
echo "$size"
EOF

    [ "$status" -eq 0 ]
    [ "$output" -ge 10 ]
}

@test "opt_fix_broken_configs reports fixes (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; opt_fix_broken_configs'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "opt_memory_pressure_relief skips when pressure is normal (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; opt_memory_pressure_relief'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "opt_memory_pressure_relief executes purge when pressure is high (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; opt_memory_pressure_relief'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}

@test "opt_spotlight_index_optimize skips when search is fast (safety closure)" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; opt_spotlight_index_optimize'
    [ "$status" -eq 1 ]
    [[ "$output" == *"disabled by the Atlas safety policy"* ]]
}
