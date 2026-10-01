#!/bin/bash
# Application Data Cleanup Module
set -euo pipefail

readonly ORPHAN_AGE_THRESHOLD=${ORPHAN_AGE_THRESHOLD:-${MOLE_ORPHAN_AGE_DAYS:-30}}
readonly CLAUDE_VM_ORPHAN_AGE_THRESHOLD=${MOLE_CLAUDE_VM_ORPHAN_AGE_DAYS:-7}
# Args: $1=target_dir, $2=label
clean_ds_store_tree() {
    local target="$1"
    local label="$2"
    [[ -d "$target" ]] || return 0
    local file_count=0
    local total_bytes=0
    local spinner_active="false"
    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  "
        start_inline_spinner "Cleaning Finder metadata..."
        spinner_active="true"
    fi
    local -a exclude_paths=(
        -path "*/Library/Application Support/MobileSync" -prune -o
        -path "*/Library/Developer" -prune -o
        -path "*/.Trash" -prune -o
        -path "*/node_modules" -prune -o
        -path "*/.git" -prune -o
        -path "*/Library/Caches" -prune -o
    )
    local -a find_cmd=("command" "find" "$target")
    if [[ "$target" == "$HOME" ]]; then
        find_cmd+=("-maxdepth" "5")
    fi
    find_cmd+=("${exclude_paths[@]}" "-type" "f" "-name" ".DS_Store" "-print0")
    while IFS= read -r -d '' ds_file; do
        local size
        size=$(get_file_size "$ds_file")
        total_bytes=$((total_bytes + size))
        file_count=$((file_count + 1))
        if [[ "$DRY_RUN" != "true" ]]; then
            safe_remove "$ds_file" true || true
        fi
        if [[ $file_count -ge $MOLE_MAX_DS_STORE_FILES ]]; then
            break
        fi
    done < <("${find_cmd[@]}" 2> /dev/null || true)
    if [[ "$spinner_active" == "true" ]]; then
        stop_section_spinner
    fi
    if [[ $file_count -gt 0 ]]; then
        local size_human
        size_human=$(bytes_to_human "$total_bytes")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $label${NC}, ${YELLOW}$file_count files, $size_human dry${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $label${NC}, ${GREEN}$file_count files, $size_human${NC}"
        fi
        local size_kb=$(((total_bytes + 1023) / 1024))
        files_cleaned=$((files_cleaned + file_count))
        total_size_cleaned=$((total_size_cleaned + size_kb))
        total_items=$((total_items + 1))
        note_activity
    fi
}
# Orphaned app data (30+ days inactive). Env: ORPHAN_AGE_THRESHOLD, DRY_RUN
# Usage: scan_installed_apps "output_file"
scan_installed_apps() {
    local installed_bundles="$1"
    # Cache installed app scan briefly to speed repeated runs.
    local cache_file="$HOME/.cache/mole/installed_apps_cache"
    local cache_age_seconds=300 # 5 minutes
    if [[ -f "$cache_file" ]]; then
        local cache_mtime=$(get_file_mtime "$cache_file")
        local current_time
        current_time=$(get_epoch_seconds)
        local age=$((current_time - cache_mtime))
        if [[ $age -lt $cache_age_seconds ]]; then
            debug_log "Using cached app list, age: ${age}s"
            if [[ -r "$cache_file" ]] && [[ -s "$cache_file" ]]; then
                if cat "$cache_file" > "$installed_bundles" 2> /dev/null; then
                    return 0
                else
                    debug_log "Warning: Failed to read cache, rebuilding"
                fi
            else
                debug_log "Warning: Cache file empty or unreadable, rebuilding"
            fi
        fi
    fi
    debug_log "Scanning installed applications, cache expired or missing"
    local -a app_dirs=(
        "/Applications"
        "/System/Applications"
        "$HOME/Applications"
        # Homebrew Cask locations
        "/opt/homebrew/Caskroom"
        "/usr/local/Caskroom"
        # Setapp applications
        "$HOME/Library/Application Support/Setapp/Applications"
    )
    # Temp dir avoids write contention across parallel scans.
    local scan_tmp_dir=$(create_temp_dir)
    local pids=()
    local dir_idx=0
    for app_dir in "${app_dirs[@]}"; do
        [[ -d "$app_dir" ]] || continue
        (
            local -a app_paths=()
            while IFS= read -r app_path; do
                [[ -n "$app_path" ]] && app_paths+=("$app_path")
            done < <(find "$app_dir" -name '*.app' -maxdepth 3 -type d 2> /dev/null)
            local count=0
            for app_path in "${app_paths[@]:-}"; do
                local plist_path="$app_path/Contents/Info.plist"
                [[ ! -f "$plist_path" ]] && continue
                local bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist_path" 2> /dev/null || echo "")
                if [[ -n "$bundle_id" ]]; then
                    echo "$bundle_id"
                    count=$((count + 1))
                fi
            done
        ) > "$scan_tmp_dir/apps_${dir_idx}.txt" &
        pids+=($!)
        dir_idx=$((dir_idx + 1))
    done
    # Collect running apps and LaunchAgents to avoid false orphan cleanup.
    (
        local running_apps=$(run_with_timeout 5 osascript -e 'tell application "System Events" to get bundle identifier of every application process' 2> /dev/null || echo "")
        echo "$running_apps" | tr ',' '\n' | sed -e 's/^ *//;s/ *$//' -e '/^$/d' > "$scan_tmp_dir/running.txt"
        # Fallback: lsappinfo is more reliable than osascript
        if command -v lsappinfo > /dev/null 2>&1; then
            run_with_timeout 3 lsappinfo list 2> /dev/null | grep -o '"CFBundleIdentifier"="[^"]*"' | cut -d'"' -f4 >> "$scan_tmp_dir/running.txt" 2> /dev/null || true
        fi
    ) &
    pids+=($!)
    (
        run_with_timeout 5 find ~/Library/LaunchAgents /Library/LaunchAgents \
            -name "*.plist" -type f 2> /dev/null |
            xargs -I {} basename {} .plist > "$scan_tmp_dir/agents.txt" 2> /dev/null || true
    ) &
    pids+=($!)
    debug_log "Waiting for ${#pids[@]} background processes: ${pids[*]}"
    if [[ ${#pids[@]} -gt 0 ]]; then
        for pid in "${pids[@]}"; do
            wait "$pid" 2> /dev/null || true
        done
    fi
    debug_log "All background processes completed"
    cat "$scan_tmp_dir"/*.txt >> "$installed_bundles" 2> /dev/null || true
    safe_remove "$scan_tmp_dir" true
    sort -u "$installed_bundles" -o "$installed_bundles"
    ensure_user_dir "$(dirname "$cache_file")"
    cp "$installed_bundles" "$cache_file" 2> /dev/null || true
    local app_count=$(wc -l < "$installed_bundles" 2> /dev/null | tr -d ' ')
    debug_log "Scanned $app_count unique applications"
}
# Sensitive data patterns that should never be treated as orphaned
# These patterns protect security-critical application data
readonly ORPHAN_NEVER_DELETE_PATTERNS=(
    "*1password*" "*1Password*"
    "*keychain*" "*Keychain*"
    "*bitwarden*" "*Bitwarden*"
    "*lastpass*" "*LastPass*"
    "*keepass*" "*KeePass*"
    "*dashlane*" "*Dashlane*"
    "*enpass*" "*Enpass*"
    "*ssh*" "*gpg*" "*gnupg*"
    "com.apple.keychain*"
)

# Cache file for mdfind results (Bash 3.2 compatible, no associative arrays)
ORPHAN_MDFIND_CACHE_FILE=""

# Usage: is_bundle_orphaned "bundle_id" "directory_path" "installed_bundles_file"
is_bundle_orphaned() {
    local bundle_id="$1"
    local directory_path="$2"
    local installed_bundles="$3"

    # 1. Fast path: check protection list (in-memory, instant)
    if should_protect_data "$bundle_id"; then
        return 1
    fi

    # 2. Fast path: check sensitive data patterns (in-memory, instant)
    local bundle_lower
    bundle_lower=$(echo "$bundle_id" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    for pattern in "${ORPHAN_NEVER_DELETE_PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$bundle_lower" == $pattern ]]; then
            return 1
        fi
    done

    # 3. Fast path: check installed bundles file (file read, fast)
    if grep -Fxq "$bundle_id" "$installed_bundles" 2> /dev/null; then
        return 1
    fi

    # 4. Fast path: hardcoded system components
    case "$bundle_id" in
        loginwindow | dock | systempreferences | systemsettings | settings | controlcenter | finder | safari)
            return 1
            ;;
    esac

    # 5. Fast path: 30-day modification check (stat call, fast)
    if [[ -e "$directory_path" ]]; then
        local last_modified_epoch=$(get_file_mtime "$directory_path")
        local current_epoch
        current_epoch=$(get_epoch_seconds)
        local days_since_modified=$(((current_epoch - last_modified_epoch) / 86400))
        if [[ $days_since_modified -lt ${ORPHAN_AGE_THRESHOLD:-30} ]]; then
            return 1
        fi
    fi

    # 6. Slow path: mdfind fallback with file-based caching (Bash 3.2 compatible)
    # This catches apps installed in non-standard locations
    if [[ -n "$bundle_id" ]] && [[ "$bundle_id" =~ ^[a-zA-Z0-9._-]+$ ]] && [[ ${#bundle_id} -ge 5 ]]; then
        # Initialize cache file if needed
        if [[ -z "$ORPHAN_MDFIND_CACHE_FILE" ]]; then
            ORPHAN_MDFIND_CACHE_FILE=$(mktemp "${TMPDIR:-/tmp}/mole_mdfind_cache.XXXXXX")
            register_temp_file "$ORPHAN_MDFIND_CACHE_FILE"
        fi

        # Check cache first (grep is fast for small files)
        if grep -Fxq "FOUND:$bundle_id" "$ORPHAN_MDFIND_CACHE_FILE" 2> /dev/null; then
            return 1
        fi
        if grep -Fxq "NOTFOUND:$bundle_id" "$ORPHAN_MDFIND_CACHE_FILE" 2> /dev/null; then
            # Already checked, not found - continue to return 0
            :
        else
            # Query mdfind with strict timeout (2 seconds max)
            local app_exists
            app_exists=$(run_with_timeout 2 mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null | head -1 || echo "")
            if [[ -n "$app_exists" ]]; then
                echo "FOUND:$bundle_id" >> "$ORPHAN_MDFIND_CACHE_FILE"
                return 1
            else
                echo "NOTFOUND:$bundle_id" >> "$ORPHAN_MDFIND_CACHE_FILE"
            fi
        fi
    fi

    # All checks passed - this is an orphan
    return 0
}

is_claude_vm_bundle_orphaned() {
    local vm_bundle_path="$1"
    local installed_bundles="$2"
    local claude_bundle_id="com.anthropic.claudefordesktop"

    [[ -d "$vm_bundle_path" ]] || return 1

    # Extra guard in case the running-app scan missed Claude Desktop.
    if pgrep -x "Claude" > /dev/null 2>&1; then
        return 1
    fi

    if grep -Fxq "$claude_bundle_id" "$installed_bundles" 2> /dev/null; then
        return 1
    fi

    if [[ -e "$vm_bundle_path" ]]; then
        local last_modified_epoch
        last_modified_epoch=$(get_file_mtime "$vm_bundle_path")
        local current_epoch
        current_epoch=$(get_epoch_seconds)
        local days_since_modified=$(((current_epoch - last_modified_epoch) / 86400))
        if [[ $days_since_modified -lt ${CLAUDE_VM_ORPHAN_AGE_THRESHOLD:-7} ]]; then
            return 1
        fi
    fi

    if [[ -z "$ORPHAN_MDFIND_CACHE_FILE" ]]; then
        ORPHAN_MDFIND_CACHE_FILE=$(mktemp "${TMPDIR:-/tmp}/mole_mdfind_cache.XXXXXX")
        register_temp_file "$ORPHAN_MDFIND_CACHE_FILE"
    fi

    if grep -Fxq "FOUND:$claude_bundle_id" "$ORPHAN_MDFIND_CACHE_FILE" 2> /dev/null; then
        return 1
    fi
    if ! grep -Fxq "NOTFOUND:$claude_bundle_id" "$ORPHAN_MDFIND_CACHE_FILE" 2> /dev/null; then
        local app_exists
        app_exists=$(run_with_timeout 2 mdfind "kMDItemCFBundleIdentifier == '$claude_bundle_id'" 2> /dev/null | head -1 || echo "")
        if [[ -n "$app_exists" ]]; then
            echo "FOUND:$claude_bundle_id" >> "$ORPHAN_MDFIND_CACHE_FILE"
            return 1
        fi
        echo "NOTFOUND:$claude_bundle_id" >> "$ORPHAN_MDFIND_CACHE_FILE"
    fi

    return 0
}

# Orphaned app data sweep.
clean_orphaned_app_data() {
    if ! ls "$HOME/Library/Caches" > /dev/null 2>&1; then
        stop_section_spinner
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Skipped: No permission to access Library folders"
        return 0
    fi
    start_section_spinner "Scanning installed apps..."
    local installed_bundles=$(create_temp_file)
    scan_installed_apps "$installed_bundles"
    stop_section_spinner
    local app_count=$(wc -l < "$installed_bundles" 2> /dev/null | tr -d ' ')
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Found $app_count active/installed apps"
    local orphaned_count=0
    local total_orphaned_kb=0
    start_section_spinner "Scanning orphaned app resources..."

    local claude_vm_bundle="$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
    if is_claude_vm_bundle_orphaned "$claude_vm_bundle" "$installed_bundles"; then
        local claude_vm_size_kb
        claude_vm_size_kb=$(get_path_size_kb "$claude_vm_bundle")
        if [[ -n "$claude_vm_size_kb" && "$claude_vm_size_kb" != "0" ]]; then
            if safe_clean "$claude_vm_bundle" "Orphaned Claude workspace VM"; then
                orphaned_count=$((orphaned_count + 1))
                total_orphaned_kb=$((total_orphaned_kb + claude_vm_size_kb))
            fi
        fi
    fi

    # CRITICAL: NEVER add LaunchAgents or LaunchDaemons (breaks login items/startup apps).
    local -a resource_types=(
        "$HOME/Library/Caches|Caches|com.*:org.*:net.*:io.*"
        "$HOME/Library/Logs|Logs|com.*:org.*:net.*:io.*"
        "$HOME/Library/Saved Application State|States|*.savedState"
        "$HOME/Library/WebKit|WebKit|com.*:org.*:net.*:io.*"
        "$HOME/Library/HTTPStorages|HTTP|com.*:org.*:net.*:io.*"
        "$HOME/Library/Cookies|Cookies|*.binarycookies"
    )
    for resource_type in "${resource_types[@]}"; do
        IFS='|' read -r base_path label patterns <<< "$resource_type"
        if [[ ! -d "$base_path" ]]; then
            continue
        fi
        if ! ls "$base_path" > /dev/null 2>&1; then
            continue
        fi
        local -a file_patterns=()
        IFS=':' read -ra pattern_arr <<< "$patterns"
        for pat in "${pattern_arr[@]}"; do
            file_patterns+=("$base_path/$pat")
        done
        if [[ ${#file_patterns[@]} -gt 0 ]]; then
            local _nullglob_state
            _nullglob_state=$(shopt -p nullglob || true)
            shopt -s nullglob
            for item_path in "${file_patterns[@]}"; do
                local iteration_count=0
                local old_ifs=$IFS
                IFS=$'\n'
                local -a matches=()
                # shellcheck disable=SC2206
                matches=($item_path)
                IFS=$old_ifs
                if [[ ${#matches[@]} -eq 0 ]]; then
                    continue
                fi
                for match in "${matches[@]}"; do
                    [[ -e "$match" ]] || continue
                    iteration_count=$((iteration_count + 1))
                    if [[ $iteration_count -gt $MOLE_MAX_ORPHAN_ITERATIONS ]]; then
                        break
                    fi
                    local bundle_id=$(basename "$match")
                    bundle_id="${bundle_id%.savedState}"
                    bundle_id="${bundle_id%.binarycookies}"
                    if is_bundle_orphaned "$bundle_id" "$match" "$installed_bundles"; then
                        local size_kb
                        size_kb=$(get_path_size_kb "$match")
                        if [[ -z "$size_kb" || "$size_kb" == "0" ]]; then
                            continue
                        fi
                        if safe_clean "$match" "Orphaned $label: $bundle_id"; then
                            orphaned_count=$((orphaned_count + 1))
                            total_orphaned_kb=$((total_orphaned_kb + size_kb))
                        fi
                    fi
                done
            done
            eval "$_nullglob_state"
        fi
    done
    stop_section_spinner
    if [[ $orphaned_count -gt 0 ]]; then
        local orphaned_mb=$(echo "$total_orphaned_kb" | awk '{printf "%.1f", $1/1024}')
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Cleaned $orphaned_count items, about ${orphaned_mb}MB"
        note_activity
    fi
    rm -f "$installed_bundles"
}

# Clean orphaned system-level services (LaunchDaemons, LaunchAgents, PrivilegedHelperTools)
# These are left behind when apps are uninstalled but their system services remain
clean_orphaned_system_services() {
    printf '%s\n' "Skipped: system-managed files and services require manual review." >&2
    return 0
}

# ============================================================================
# Orphaned LaunchAgent/LaunchDaemon Cleanup (Generic Detection)
# ============================================================================

# Extract program path from plist (supports both ProgramArguments and Program)
_extract_program_path() {
    local plist="$1"
    local program=""

    program=$(plutil -extract ProgramArguments.0 raw "$plist" 2> /dev/null)
    if [[ -z "$program" ]]; then
        program=$(plutil -extract Program raw "$plist" 2> /dev/null)
    fi

    echo "$program"
}

# Extract associated bundle identifier from plist
_extract_associated_bundle() {
    local plist="$1"
    local associated=""

    # Try array format first
    associated=$(plutil -extract AssociatedBundleIdentifiers.0 raw "$plist" 2> /dev/null)
    if [[ -z "$associated" ]] || [[ "$associated" == "1" ]]; then
        # Try string format
        associated=$(plutil -extract AssociatedBundleIdentifiers raw "$plist" 2> /dev/null)
        # Filter out dict/array markers
        if [[ "$associated" == "{"* ]] || [[ "$associated" == "["* ]]; then
            associated=""
        fi
    fi

    echo "$associated"
}

# Check if a LaunchAgent/LaunchDaemon is orphaned using multi-layer verification
# Returns 0 if orphaned, 1 if not orphaned
is_launch_item_orphaned() {
    local plist="$1"

    # Layer 1: Check if program path exists
    local program=$(_extract_program_path "$plist")

    # No program path - skip (not a standard launch item)
    [[ -z "$program" ]] && return 1

    # Program exists -> not orphaned
    [[ -e "$program" ]] && return 1

    # Layer 2: Check AssociatedBundleIdentifiers
    local associated=$(_extract_associated_bundle "$plist")
    if [[ -n "$associated" ]]; then
        # Check if associated app exists via mdfind
        if run_with_timeout 2 mdfind "kMDItemCFBundleIdentifier == '$associated'" 2> /dev/null | head -1 | grep -q .; then
            return 1 # Associated app found -> not orphaned
        fi

        # Extract vendor name from bundle ID (com.vendor.app -> vendor)
        local vendor=$(echo "$associated" | cut -d'.' -f2)
        if [[ -n "$vendor" ]] && [[ ${#vendor} -ge 3 ]]; then
            # Check if any app from this vendor exists
            if find /Applications ~/Applications -maxdepth 2 -iname "*${vendor}*" -type d 2> /dev/null | grep -iq "\.app"; then
                return 1 # Vendor app exists -> not orphaned
            fi
        fi
    fi

    # Layer 3: Check Application Support directory activity
    if [[ "$program" =~ /Library/Application\ Support/([^/]+)/ ]]; then
        local app_support_name="${BASH_REMATCH[1]}"

        # Check both user and system Application Support
        for base in "$HOME/Library/Application Support" "/Library/Application Support"; do
            local support_path="$base/$app_support_name"
            if [[ -d "$support_path" ]]; then
                # Check if there are files modified in last 7 days (active usage)
                local recent_file=$(find "$support_path" -type f -mtime -7 2> /dev/null | head -1)
                if [[ -n "$recent_file" ]]; then
                    return 1 # Active Application Support -> not orphaned
                fi
            fi
        done
    fi

    # Layer 4: Check if app name from program path exists
    if [[ "$program" =~ /Applications/([^/]+)\.app/ ]]; then
        local app_name="${BASH_REMATCH[1]}"
        # Look for apps with similar names (case-insensitive)
        if find /Applications ~/Applications -maxdepth 2 -iname "*${app_name}*" -type d 2> /dev/null | grep -iq "\.app"; then
            return 1 # Similar app exists -> not orphaned
        fi
    fi

    # Layer 5: PrivilegedHelper special handling
    if [[ "$program" =~ ^/Library/PrivilegedHelperTools/ ]]; then
        local filename=$(basename "$plist")
        local bundle_id="${filename%.plist}"

        # Extract app hint from bundle ID (com.vendor.app.helper -> vendor)
        local app_hint=$(echo "$bundle_id" | sed 's/com\.//; s/\..*helper.*//')

        if [[ -n "$app_hint" ]] && [[ ${#app_hint} -ge 3 ]]; then
            # Look for main app
            if find /Applications ~/Applications -maxdepth 2 -iname "*${app_hint}*" -type d 2> /dev/null | grep -iq "\.app"; then
                return 1 # Helper's main app exists -> not orphaned
            fi
        fi
    fi

    # All checks failed -> likely orphaned
    return 0
}

# Clean orphaned user-level LaunchAgents
# Only processes ~/Library/LaunchAgents (safer than system-level)
clean_orphaned_launch_agents() {
    printf '%s\n' "Skipped: system-managed files and services require manual review." >&2
    return 0
}
