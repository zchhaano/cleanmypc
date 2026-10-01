#!/bin/bash
# Mole - File Operations
# Safe file and directory manipulation with validation

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_FILE_OPS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_FILE_OPS_LOADED=1

# Error codes for removal operations
readonly MOLE_ERR_SIP_PROTECTED=10
readonly MOLE_ERR_AUTH_FAILED=11
readonly MOLE_ERR_READONLY_FS=12

# Ensure dependencies are loaded
_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_BASE_LOADED:-}" ]]; then
    # shellcheck source=lib/core/base.sh
    source "$_MOLE_CORE_DIR/base.sh"
fi
if [[ -z "${MOLE_LOG_LOADED:-}" ]]; then
    # shellcheck source=lib/core/log.sh
    source "$_MOLE_CORE_DIR/log.sh"
fi
if [[ -z "${MOLE_TIMEOUT_LOADED:-}" ]]; then
    # shellcheck source=lib/core/timeout.sh
    source "$_MOLE_CORE_DIR/timeout.sh"
fi

# ============================================================================
# Utility Functions
# ============================================================================

# Format duration in seconds to human readable string (e.g., "5 days", "2 months")
format_duration_human() {
    local seconds="${1:-0}"
    [[ ! "$seconds" =~ ^[0-9]+$ ]] && seconds=0

    local days=$((seconds / 86400))

    if [[ $days -eq 0 ]]; then
        echo "today"
    elif [[ $days -eq 1 ]]; then
        echo "1 day"
    elif [[ $days -lt 7 ]]; then
        echo "${days} days"
    elif [[ $days -lt 30 ]]; then
        local weeks=$((days / 7))
        [[ $weeks -eq 1 ]] && echo "1 week" || echo "${weeks} weeks"
    elif [[ $days -lt 365 ]]; then
        local months=$((days / 30))
        [[ $months -eq 1 ]] && echo "1 month" || echo "${months} months"
    else
        local years=$((days / 365))
        [[ $years -eq 1 ]] && echo "1 year" || echo "${years} years"
    fi
}

# ============================================================================
# Path Validation
# ============================================================================

# Validate path for deletion (absolute, no traversal, not system dir)
validate_path_for_deletion() {
    local path="$1"

    # Check path is not empty
    if [[ -z "$path" ]]; then
        log_error "Path validation failed: empty path"
        return 1
    fi

    # Check symlink target if path is a symbolic link
    if [[ -L "$path" ]]; then
        local link_target
        link_target=$(readlink "$path" 2> /dev/null) || {
            log_error "Cannot read symlink: $path"
            return 1
        }

        # Resolve relative symlinks to absolute paths for validation
        local resolved_target="$link_target"
        if [[ "$link_target" != /* ]]; then
            local link_dir
            link_dir=$(dirname "$path")
            resolved_target=$(cd "$link_dir" 2> /dev/null && cd "$(dirname "$link_target")" 2> /dev/null && pwd)/$(basename "$link_target") || resolved_target=""
        fi

        # Validate resolved target against protected paths
        if [[ -n "$resolved_target" ]]; then
            case "$resolved_target" in
                / | /System | /System/* | /bin | /bin/* | /sbin | /sbin/* | \
                    /usr | /usr/bin | /usr/bin/* | /usr/lib | /usr/lib/* | \
                    /etc | /etc/* | /private/etc | /private/etc/* | \
                    /Library/Extensions | /Library/Extensions/*)
                    log_error "Symlink points to protected system path: $path -> $resolved_target"
                    return 1
                    ;;
            esac
        fi
    fi

    # Check path is absolute
    if [[ "$path" != /* ]]; then
        log_error "Path validation failed: path must be absolute: $path"
        return 1
    fi

    # Check for path traversal attempts
    # Only reject .. when it appears as a complete path component (/../ or /.. or ../)
    # This allows legitimate directory names containing .. (e.g., Firefox's "name..files")
    if [[ "$path" =~ (^|/)\.\.(\/|$) ]]; then
        log_error "Path validation failed: path traversal not allowed: $path"
        return 1
    fi

    # Check path doesn't contain dangerous characters
    if [[ "$path" =~ [[:cntrl:]] ]] || [[ "$path" =~ $'\n' ]]; then
        log_error "Path validation failed: contains control characters: $path"
        return 1
    fi

    # Allow deletion of coresymbolicationd cache (safe system cache that can be rebuilt)
    case "$path" in
        /System/Library/Caches/com.apple.coresymbolicationd/data | /System/Library/Caches/com.apple.coresymbolicationd/data/*)
            return 0
            ;;
    esac

    # Allow known safe paths under /private
    case "$path" in
        /private/tmp | /private/tmp/* | \
            /private/var/tmp | /private/var/tmp/* | \
            /private/var/log | /private/var/log/* | \
            /private/var/folders | /private/var/folders/* | \
            /private/var/db/diagnostics | /private/var/db/diagnostics/* | \
            /private/var/db/DiagnosticPipeline | /private/var/db/DiagnosticPipeline/* | \
            /private/var/db/powerlog | /private/var/db/powerlog/* | \
            /private/var/db/reportmemoryexception | /private/var/db/reportmemoryexception/* | \
            /private/var/db/receipts/*.bom | /private/var/db/receipts/*.plist)
            return 0
            ;;
    esac

    # Check path isn't critical system directory
    case "$path" in
        / | /bin | /bin/* | /sbin | /sbin/* | /usr | /usr/bin | /usr/bin/* | /usr/sbin | /usr/sbin/* | /usr/lib | /usr/lib/* | /System | /System/* | /Library/Extensions)
            log_error "Path validation failed: critical system directory: $path"
            return 1
            ;;
        /private)
            log_error "Path validation failed: critical system directory: $path"
            return 1
            ;;
        /etc | /etc/* | /private/etc | /private/etc/*)
            log_error "Path validation failed: /etc contains critical system files: $path"
            return 1
            ;;
        /var | /var/db | /var/db/* | /private/var | /private/var/db | /private/var/db/*)
            log_error "Path validation failed: /var/db contains system databases: $path"
            return 1
            ;;
    esac

    # Check if path is protected (keychains, system settings, etc)
    if declare -f should_protect_path > /dev/null 2>&1; then
        if should_protect_path "$path"; then
            if [[ "${MO_DEBUG:-0}" == "1" ]]; then
                log_warning "Path validation: protected path skipped: $path"
            fi
            return 1
        fi
    fi

    return 0
}

# ============================================================================
# Safe Removal Operations
# ============================================================================

# Safe wrapper around rm -rf with validation
safe_remove() {
    local path="${1:-}"
    validate_path_for_deletion "$path" || return 1
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        log_info "[DRY-RUN] Review candidate: $path"
        return 0
    fi
    printf '%s\n' "Not executed: cache deletion requires the confined safe-remove backend." >&2
    return 1
}

# Safe symlink removal (for pre-validated symlinks only)
safe_remove_symlink() {
    printf '%s\n' "Not executed: this operation is disabled by the Atlas safety policy." >&2
    return 1
}

# Safe sudo removal with symlink protection
safe_sudo_remove() {
    printf '%s\n' "Not executed: this operation is disabled by the Atlas safety policy." >&2
    return 1
}

# ============================================================================
# Safe Find and Delete Operations
# ============================================================================

# Safe file discovery and deletion with depth and age limits
safe_find_delete() {
    local base_dir="$1"
    local pattern="$2"
    local age_days="${3:-7}"
    local type_filter="${4:-f}"

    # Validate base directory exists and is not a symlink
    if [[ ! -d "$base_dir" ]]; then
        log_error "Directory does not exist: $base_dir"
        return 1
    fi

    if [[ -L "$base_dir" ]]; then
        log_error "Refusing to search symlinked directory: $base_dir"
        return 1
    fi

    # Validate type filter
    if [[ "$type_filter" != "f" && "$type_filter" != "d" ]]; then
        log_error "Invalid type filter: $type_filter, must be 'f' or 'd'"
        return 1
    fi

    debug_log "Finding in $base_dir: $pattern, age: ${age_days}d, type: $type_filter"

    local find_args=("-maxdepth" "5" "-name" "$pattern" "-type" "$type_filter")
    if [[ "$age_days" -gt 0 ]]; then
        find_args+=("-mtime" "+$age_days")
    fi

    # Iterate results to respect should_protect_path
    while IFS= read -r -d '' match; do
        if should_protect_path "$match"; then
            continue
        fi
        safe_remove "$match" true || true
    done < <(command find "$base_dir" "${find_args[@]}" -print0 2> /dev/null || true)

    return 0
}

# Safe sudo discovery and deletion
safe_sudo_find_delete() {
    local base_dir="$1"
    local pattern="$2"
    local age_days="${3:-7}"
    local type_filter="${4:-f}"

    # Validate base directory (use sudo for permission-restricted dirs)
    if ! sudo test -d "$base_dir" 2> /dev/null; then
        debug_log "Directory does not exist, skipping: $base_dir"
        return 0
    fi

    if sudo test -L "$base_dir" 2> /dev/null; then
        log_error "Refusing to search symlinked directory: $base_dir"
        return 1
    fi

    # Validate type filter
    if [[ "$type_filter" != "f" && "$type_filter" != "d" ]]; then
        log_error "Invalid type filter: $type_filter, must be 'f' or 'd'"
        return 1
    fi

    debug_log "Finding, sudo, in $base_dir: $pattern, age: ${age_days}d, type: $type_filter"

    local find_args=("-maxdepth" "5")
    # Skip -name if pattern is "*" (matches everything anyway, but adds overhead)
    if [[ "$pattern" != "*" ]]; then
        find_args+=("-name" "$pattern")
    fi
    find_args+=("-type" "$type_filter")
    if [[ "$age_days" -gt 0 ]]; then
        find_args+=("-mtime" "+$age_days")
    fi

    # Iterate results to respect should_protect_path
    while IFS= read -r -d '' match; do
        if should_protect_path "$match"; then
            continue
        fi
        safe_sudo_remove "$match" || true
    done < <(sudo find "$base_dir" "${find_args[@]}" -print0 2> /dev/null || true)

    return 0
}

# ============================================================================
# Size Calculation
# ============================================================================

# Get path size in KB (returns 0 if not found)
get_path_size_kb() {
    local path="$1"
    [[ -z "$path" || ! -e "$path" ]] && {
        echo "0"
        return
    }

    # For .app bundles, prefer mdls logical size as it matches Finder
    # (APFS clone/sparse files make 'du' severely underreport apps like Xcode)
    if [[ "$path" == *.app || "$path" == *.app/ ]]; then
        local mdls_size
        mdls_size=$(mdls -name kMDItemLogicalSize -raw "$path" 2> /dev/null || true)
        if [[ "$mdls_size" =~ ^[0-9]+$ && "$mdls_size" -gt 0 ]]; then
            # Return in KB
            echo "$((mdls_size / 1024))"
            return
        fi
    fi

    local size
    size=$(command du -skP "$path" 2> /dev/null | awk 'NR==1 {print $1; exit}' || true)

    if [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "$size"
    else
        [[ "${MO_DEBUG:-}" == "1" ]] && debug_log "get_path_size_kb: Failed to get size for $path (returned: $size)"
        echo "0"
    fi
}

# Calculate total size for multiple paths
calculate_total_size() {
    local files="$1"
    local total_kb=0

    while IFS= read -r file; do
        if [[ -n "$file" && -e "$file" ]]; then
            local size_kb
            size_kb=$(get_path_size_kb "$file")
            total_kb=$((total_kb + size_kb))
        fi
    done <<< "$files"

    echo "$total_kb"
}

diagnose_removal_failure() {
    local exit_code="$1"
    local app_name="${2:-application}"

    local reason=""
    local suggestion=""
    local touchid_file="/etc/pam.d/sudo"

    case "$exit_code" in
        "$MOLE_ERR_SIP_PROTECTED")
            reason="protected by macOS (SIP/MDM)"
            ;;
        "$MOLE_ERR_AUTH_FAILED")
            reason="authentication failed"
            if [[ -f "$touchid_file" ]] && grep -q "pam_tid.so" "$touchid_file" 2> /dev/null; then
                suggestion="Check your credentials or restart Terminal"
            else
                suggestion="Try 'mole touchid' to enable fingerprint auth"
            fi
            ;;
        "$MOLE_ERR_READONLY_FS")
            reason="filesystem is read-only"
            suggestion="Check if disk needs repair"
            ;;
        *)
            reason="permission denied"
            if [[ -f "$touchid_file" ]] && grep -q "pam_tid.so" "$touchid_file" 2> /dev/null; then
                suggestion="Try running again or check file ownership"
            else
                suggestion="Try 'mole touchid' or check with 'ls -l'"
            fi
            ;;
    esac

    echo "$reason|$suggestion"
}
