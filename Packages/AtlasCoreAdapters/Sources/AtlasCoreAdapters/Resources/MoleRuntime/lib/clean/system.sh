#!/bin/bash
# System-Level Cleanup Module (requires sudo).
set -euo pipefail
# System caches, logs, and temp files.
clean_deep_system() {
    printf '%s\n' "Skipped: system-managed files and services require manual review." >&2
    return 0
}
# Backup deletion is unavailable, regardless of status detection or dry-run flags.
clean_time_machine_failed_backups() {
    printf '%s\n' "Skipped: external-tool deletion is disabled by the Atlas safety policy."
}
# Returns 0 if a backup is actively running.
# Returns 1 if not running.
# Returns 2 if status cannot be determined
tm_is_running() {
    local st
    st="$(tmutil status 2> /dev/null)" || return 2

    # If we can't find a Running field at all, treat as unknown.
    if ! grep -qE '(^|[[:space:]])("Running"|Running)[[:space:]]*=' <<< "$st"; then
        return 2
    fi

    # Match: Running = 1;   OR   "Running" = 1   (with or without trailing ;)
    grep -qE '(^|[[:space:]])("Running"|Running)[[:space:]]*=[[:space:]]*1([[:space:]]*;|$)' <<< "$st"
}

# Local APFS snapshots (report only).
clean_local_snapshots() {
    if ! command -v tmutil > /dev/null 2>&1; then
        return 0
    fi
    # Fast pre-check: skip entirely if Time Machine is not configured (no tmutil needed)
    if ! defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2> /dev/null | grep -qE '^[01]$'; then
        return 0
    fi

    start_section_spinner "Checking Time Machine status..."
    local rc_running=0
    tm_is_running || rc_running=$?

    if [[ $rc_running -eq 2 ]]; then
        stop_section_spinner
        echo -e "  ${YELLOW}!${NC} Could not determine Time Machine status; skipping snapshot check"
        return 0
    fi

    if [[ $rc_running -eq 0 ]]; then
        stop_section_spinner
        echo -e "  ${YELLOW}!${NC} Time Machine is active; skipping snapshot check"
        return 0
    fi

    start_section_spinner "Checking local snapshots..."
    local snapshot_list
    snapshot_list=$(run_with_timeout 3 tmutil listlocalsnapshots / 2> /dev/null || true)
    stop_section_spinner
    [[ -z "$snapshot_list" ]] && return 0

    local snapshot_count
    snapshot_count=$(echo "$snapshot_list" | { grep -Eo 'com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' || true; } | wc -l | awk '{print $1}')
    if [[ "$snapshot_count" =~ ^[0-9]+$ && "$snapshot_count" -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Time Machine local snapshots: ${GREEN}${snapshot_count}${NC}"
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} ${GRAY}Review: tmutil listlocalsnapshots /${NC}"
        note_activity
    fi
}
