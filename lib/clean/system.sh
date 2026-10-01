#!/bin/bash
# System-Level Cleanup Module (requires sudo).
set -euo pipefail
# System caches, logs, and temp files.
clean_deep_system() {
    printf '%s\n' "Skipped: system-managed files and services require manual review." >&2
    return 0
}
# Incomplete Time Machine backups.
clean_time_machine_failed_backups() {
    local tm_cleaned=0
    if ! command -v tmutil > /dev/null 2>&1; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    # Fast pre-check: skip entirely if Time Machine is not configured (no tmutil needed)
    if ! defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2> /dev/null | grep -qE '^[01]$'; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    start_section_spinner "Checking Time Machine configuration..."
    local spinner_active=true
    local tm_info
    tm_info=$(run_with_timeout 2 tmutil destinationinfo 2>&1 || echo "failed")
    if [[ "$tm_info" == *"No destinations configured"* || "$tm_info" == "failed" ]]; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    if [[ ! -d "/Volumes" ]]; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    if tm_is_running; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        echo -e "  ${YELLOW}!${NC} Time Machine backup in progress, skipping cleanup"
        return 0
    fi
    if [[ "$spinner_active" == "true" ]]; then
        start_section_spinner "Checking backup volumes..."
    fi
    # Fast pre-scan for backup volumes to avoid slow tmutil checks.
    local -a backup_volumes=()
    for volume in /Volumes/*; do
        [[ -d "$volume" ]] || continue
        [[ "$volume" == "/Volumes/MacintoshHD" || "$volume" == "/" ]] && continue
        [[ -L "$volume" ]] && continue
        if [[ -d "$volume/Backups.backupdb" ]] || [[ -d "$volume/.MobileBackups" ]]; then
            backup_volumes+=("$volume")
        fi
    done
    if [[ ${#backup_volumes[@]} -eq 0 ]]; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    if [[ "$spinner_active" == "true" ]]; then
        start_section_spinner "Scanning backup volumes..."
    fi
    for volume in "${backup_volumes[@]}"; do
        local fs_type
        fs_type=$(run_with_timeout 1 command df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}' || echo "unknown")
        case "$fs_type" in
            nfs | smbfs | afpfs | cifs | webdav | unknown) continue ;;
        esac
        local backupdb_dir="$volume/Backups.backupdb"
        if [[ -d "$backupdb_dir" ]]; then
            while IFS= read -r inprogress_file; do
                [[ -d "$inprogress_file" ]] || continue
                # Only delete old incomplete backups (safety window).
                local file_mtime
                file_mtime=$(get_file_mtime "$inprogress_file")
                local current_time
                current_time=$(get_epoch_seconds)
                local hours_old=$(((current_time - file_mtime) / 3600))
                if [[ $hours_old -lt $MOLE_TM_BACKUP_SAFE_HOURS ]]; then
                    continue
                fi
                local size_kb
                size_kb=$(get_path_size_kb "$inprogress_file")
                [[ "$size_kb" -le 0 ]] && continue
                if [[ "$spinner_active" == "true" ]]; then
                    stop_section_spinner
                    spinner_active=false
                fi
                local backup_name
                backup_name=$(basename "$inprogress_file")
                local size_human
                size_human=$(bytes_to_human "$((size_kb * 1024))")
                if [[ "$DRY_RUN" == "true" ]]; then
                    echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Incomplete backup: $backup_name${NC}, ${YELLOW}$size_human dry${NC}"
                    tm_cleaned=$((tm_cleaned + 1))
                    note_activity
                    continue
                fi
                if ! command -v tmutil > /dev/null 2>&1; then
                    echo -e "  ${YELLOW}!${NC} tmutil not available, skipping: $backup_name"
                    continue
                fi
                if tmutil delete "$inprogress_file" 2> /dev/null; then
                    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Incomplete backup: $backup_name${NC}, ${GREEN}$size_human${NC}"
                    tm_cleaned=$((tm_cleaned + 1))
                    files_cleaned=$((files_cleaned + 1))
                    total_size_cleaned=$((total_size_cleaned + size_kb))
                    total_items=$((total_items + 1))
                    note_activity
                else
                    echo -e "  ${YELLOW}!${NC} Could not delete: $backup_name · try manually with sudo"
                fi
            done < <(run_with_timeout 15 find "$backupdb_dir" -maxdepth 3 -type d \( -name "*.inProgress" -o -name "*.inprogress" \) 2> /dev/null || true)
        fi
        # APFS bundles.
        for bundle in "$volume"/*.backupbundle "$volume"/*.sparsebundle; do
            [[ -e "$bundle" ]] || continue
            [[ -d "$bundle" ]] || continue
            local bundle_name
            bundle_name=$(basename "$bundle")
            local mounted_path
            mounted_path=$(hdiutil info 2> /dev/null | grep -A 5 "image-path.*$bundle_name" | grep "/Volumes/" | awk '{print $1}' | head -1 || echo "")
            if [[ -n "$mounted_path" && -d "$mounted_path" ]]; then
                while IFS= read -r inprogress_file; do
                    [[ -d "$inprogress_file" ]] || continue
                    local file_mtime
                    file_mtime=$(get_file_mtime "$inprogress_file")
                    local current_time
                    current_time=$(get_epoch_seconds)
                    local hours_old=$(((current_time - file_mtime) / 3600))
                    if [[ $hours_old -lt $MOLE_TM_BACKUP_SAFE_HOURS ]]; then
                        continue
                    fi
                    local size_kb
                    size_kb=$(get_path_size_kb "$inprogress_file")
                    [[ "$size_kb" -le 0 ]] && continue
                    if [[ "$spinner_active" == "true" ]]; then
                        stop_section_spinner
                        spinner_active=false
                    fi
                    local backup_name
                    backup_name=$(basename "$inprogress_file")
                    local size_human
                    size_human=$(bytes_to_human "$((size_kb * 1024))")
                    if [[ "$DRY_RUN" == "true" ]]; then
                        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Incomplete APFS backup in $bundle_name: $backup_name${NC}, ${YELLOW}$size_human dry${NC}"
                        tm_cleaned=$((tm_cleaned + 1))
                        note_activity
                        continue
                    fi
                    if ! command -v tmutil > /dev/null 2>&1; then
                        continue
                    fi
                    if tmutil delete "$inprogress_file" 2> /dev/null; then
                        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Incomplete APFS backup in $bundle_name: $backup_name${NC}, ${GREEN}$size_human${NC}"
                        tm_cleaned=$((tm_cleaned + 1))
                        files_cleaned=$((files_cleaned + 1))
                        total_size_cleaned=$((total_size_cleaned + size_kb))
                        total_items=$((total_items + 1))
                        note_activity
                    else
                        echo -e "  ${YELLOW}!${NC} Could not delete from bundle: $backup_name"
                    fi
                done < <(run_with_timeout 15 find "$mounted_path" -maxdepth 3 -type d \( -name "*.inProgress" -o -name "*.inprogress" \) 2> /dev/null || true)
            fi
        done
    done
    if [[ "$spinner_active" == "true" ]]; then
        stop_section_spinner
    fi
    if [[ $tm_cleaned -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
    fi
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
