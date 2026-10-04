#!/bin/bash
# Optimization Tasks

set -euo pipefail

# Config constants (override via env).
readonly MOLE_TM_THIN_TIMEOUT=180
readonly MOLE_TM_THIN_VALUE=9999999999
readonly MOLE_SQLITE_MAX_SIZE=104857600 # 100MB

# Dry-run aware output.
opt_msg() {
    local message="$1"
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $message"
    else
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $message"
    fi
}

run_launchctl_unload() {
    printf '%s\n' "Not executed: this operation is disabled by the Atlas safety policy." >&2
    return 1
}

needs_permissions_repair() {
    local owner
    owner=$(stat -f %Su "$HOME" 2> /dev/null || echo "")
    if [[ -n "$owner" && "$owner" != "$USER" ]]; then
        return 0
    fi

    local -a paths=(
        "$HOME"
        "$HOME/Library"
        "$HOME/Library/Preferences"
    )
    local path
    for path in "${paths[@]}"; do
        if [[ -e "$path" && ! -w "$path" ]]; then
            return 0
        fi
    done

    return 1
}

has_bluetooth_hid_connected() {
    local bt_report
    bt_report=$(system_profiler SPBluetoothDataType 2> /dev/null || echo "")
    if ! echo "$bt_report" | grep -q "Connected: Yes"; then
        return 1
    fi

    if echo "$bt_report" | grep -Eiq "Keyboard|Trackpad|Mouse|HID"; then
        return 0
    fi

    return 1
}

is_ac_power() {
    pmset -g batt 2> /dev/null | grep -q "AC Power"
}

is_memory_pressure_high() {
    if ! command -v memory_pressure > /dev/null 2>&1; then
        return 1
    fi

    local mp_output
    mp_output=$(memory_pressure -Q 2> /dev/null || echo "")
    if echo "$mp_output" | grep -Eiq "warning|critical"; then
        return 0
    fi

    return 1
}

flush_dns_cache() {
    printf '%s\n' "Not executed: system and application maintenance is disabled by the Atlas safety policy." >&2
    return 1
}

opt_system_maintenance() {
    printf '%s\n' "Not executed: system and application maintenance is disabled by the Atlas safety policy." >&2
    return 1
}

opt_cache_refresh() {
    printf '%s\n' "Not executed: system and application maintenance is disabled by the Atlas safety policy." >&2
    export OPTIMIZE_CACHE_CLEANED_KB=0
    return 1
}

opt_saved_state_cleanup() {
    printf '%s\n' "Not executed: system and application maintenance is disabled by the Atlas safety policy." >&2
    return 1
}

opt_fix_broken_configs() {
    printf '%s\n' "Not executed: system and application maintenance is disabled by the Atlas safety policy." >&2
    return 1
}

opt_network_optimization() {
    printf '%s\n' "Not executed: system and application maintenance is disabled by the Atlas safety policy." >&2
    return 1
}

opt_sqlite_vacuum() {
    printf '%s\n' "Not executed: system and application maintenance is disabled by the Atlas safety policy." >&2
    return 1
}

opt_launch_services_rebuild() {
    printf '%s\n' "Not executed: system and application maintenance is disabled by the Atlas safety policy." >&2
    return 1
}

opt_font_cache_rebuild() {
    printf '%s\n' "Not executed: system and application maintenance is disabled by the Atlas safety policy." >&2
    return 1
}

opt_memory_pressure_relief() {
    printf '%s\n' "Not executed: system and application maintenance is disabled by the Atlas safety policy." >&2
    return 1
}

opt_network_stack_optimize() {
    printf '%s\n' "Not executed: this operation is disabled by the Atlas safety policy." >&2
    return 1
}

# User directory permissions repair.
opt_disk_permissions_repair() {
    printf '%s\n' "Not executed: this operation is disabled by the Atlas safety policy." >&2
    return 1
}

# Bluetooth reset (skip if HID/audio active).
opt_bluetooth_reset() {
    printf '%s\n' "Not executed: this operation is disabled by the Atlas safety policy." >&2
    return 1
}

# Spotlight index check/rebuild (only if slow).
opt_spotlight_index_optimize() {
    printf '%s\n' "Not executed: system and application maintenance is disabled by the Atlas safety policy." >&2
    return 1
}

opt_dock_refresh() {
    printf '%s\n' "Not executed: system and application maintenance is disabled by the Atlas safety policy." >&2
    return 1
}

execute_optimization() {
    local action="$1"
    local path="${2:-}"

    case "$action" in
        system_maintenance) opt_system_maintenance ;;
        cache_refresh) opt_cache_refresh ;;
        saved_state_cleanup) opt_saved_state_cleanup ;;
        fix_broken_configs) opt_fix_broken_configs ;;
        network_optimization) opt_network_optimization ;;
        sqlite_vacuum) opt_sqlite_vacuum ;;
        launch_services_rebuild) opt_launch_services_rebuild ;;
        font_cache_rebuild) opt_font_cache_rebuild ;;
        dock_refresh) opt_dock_refresh ;;
        memory_pressure_relief) opt_memory_pressure_relief ;;
        network_stack_optimize) opt_network_stack_optimize ;;
        disk_permissions_repair) opt_disk_permissions_repair ;;
        bluetooth_reset) opt_bluetooth_reset ;;
        spotlight_index_optimize) opt_spotlight_index_optimize ;;
        *)
            echo -e "${YELLOW}${ICON_ERROR}${NC} Unknown action: $action"
            return 1
            ;;
    esac
}
