#!/bin/bash
# Mole - Touch ID command.
# Configures sudo with Touch ID.
# Guided toggle with safety checks.

set -euo pipefail

# Determine script location and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Source common functions
# shellcheck source=../lib/core/common.sh
source "$LIB_DIR/core/common.sh"

# Set up global cleanup trap
trap cleanup_temp_files EXIT INT TERM

PAM_SUDO_FILE="${MOLE_PAM_SUDO_FILE:-/etc/pam.d/sudo}"
PAM_SUDO_LOCAL_FILE="${MOLE_PAM_SUDO_LOCAL_FILE:-$(dirname "$PAM_SUDO_FILE")/sudo_local}"
readonly PAM_SUDO_FILE
readonly PAM_SUDO_LOCAL_FILE
readonly PAM_TID_LINE="auth       sufficient     pam_tid.so"

# Check if Touch ID is already configured
is_touchid_configured() {
    # Check sudo_local first
    if [[ -f "$PAM_SUDO_LOCAL_FILE" ]]; then
        grep -q "pam_tid.so" "$PAM_SUDO_LOCAL_FILE" 2> /dev/null && return 0
    fi

    # Fallback to standard sudo file
    if [[ ! -f "$PAM_SUDO_FILE" ]]; then
        return 1
    fi
    grep -q "pam_tid.so" "$PAM_SUDO_FILE" 2> /dev/null
}

# Check if system supports Touch ID
supports_touchid() {
    # Check if bioutil exists and has Touch ID capability
    if command -v bioutil &> /dev/null; then
        bioutil -r 2> /dev/null | grep -q "Touch ID" && return 0
    fi

    # Fallback: check if running on Apple Silicon or modern Intel Mac
    local arch
    arch=$(uname -m)
    if [[ "$arch" == "arm64" ]]; then
        return 0
    fi

    # For Intel Macs, check if it's 2018 or later (approximation)
    local model_year
    model_year=$(system_profiler SPHardwareDataType 2> /dev/null | grep "Model Identifier" | grep -o "[0-9]\{4\}" | head -1)
    if [[ -n "$model_year" ]] && [[ "$model_year" -ge 2018 ]]; then
        return 0
    fi

    return 1
}

touchid_dry_run_enabled() {
    [[ "${MOLE_DRY_RUN:-0}" == "1" ]]
}

# Show current Touch ID status
show_status() {
    if is_touchid_configured; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Touch ID is enabled for sudo"
    else
        echo -e "${YELLOW}☻${NC} Touch ID is not configured for sudo"
    fi
}

# Enable Touch ID for sudo
enable_touchid() {
    if touchid_dry_run_enabled; then
        printf '%s\n' "[DRY RUN] Touch ID configuration is read-only; no PAM file will be modified."
        return 0
    fi
    printf '%s\n' "Not executed: this operation is disabled by the Atlas safety policy." >&2
    return 1
}

# Disable Touch ID for sudo
disable_touchid() {
    if touchid_dry_run_enabled; then
        printf '%s\n' "[DRY RUN] Touch ID configuration is read-only; no PAM file will be modified."
        return 0
    fi
    printf '%s\n' "Not executed: this operation is disabled by the Atlas safety policy." >&2
    return 1
}

# Interactive menu
show_menu() {
    echo ""
    show_status
    if is_touchid_configured; then
        echo -ne "${PURPLE}☛${NC} Press ${GREEN}Enter${NC} to disable, ${GRAY}Q${NC} to quit: "
        IFS= read -r -s -n1 key || key=""
        drain_pending_input # Clean up any escape sequence remnants
        echo ""

        case "$key" in
            $'\e') # ESC
                return 0
                ;;
            "" | $'\n' | $'\r')   # Enter
                printf "\r\033[K" # Clear the prompt line
                disable_touchid
                ;;
            *)
                echo ""
                log_error "Invalid key"
                ;;
        esac
    else
        echo -ne "${PURPLE}☛${NC} Press ${GREEN}Enter${NC} to enable, ${GRAY}Q${NC} to quit: "
        IFS= read -r -s -n1 key || key=""
        drain_pending_input # Clean up any escape sequence remnants

        case "$key" in
            $'\e') # ESC
                return 0
                ;;
            "" | $'\n' | $'\r')   # Enter
                printf "\r\033[K" # Clear the prompt line
                enable_touchid
                ;;
            *)
                echo ""
                log_error "Invalid key"
                ;;
        esac
    fi
}

# Main
main() {
    local command=""
    local arg

    for arg in "$@"; do
        case "$arg" in
            "--dry-run" | "-n")
                export MOLE_DRY_RUN=1
                ;;
            "--help" | "-h")
                show_touchid_help
                return 0
                ;;
            enable | disable | status)
                if [[ -z "$command" ]]; then
                    command="$arg"
                else
                    log_error "Only one touchid command is supported per run"
                    return 1
                fi
                ;;
            *)
                log_error "Unknown command: $arg"
                return 1
                ;;
        esac
    done

    if touchid_dry_run_enabled; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, No sudo authentication files will be modified"
        echo ""
    fi

    case "$command" in
        enable)
            enable_touchid
            ;;
        disable)
            disable_touchid
            ;;
        status)
            show_status
            ;;
        "")
            show_menu
            ;;
        *)
            log_error "Unknown command: $command"
            exit 1
            ;;
    esac
}

main "$@"
