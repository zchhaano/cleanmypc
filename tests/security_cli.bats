#!/usr/bin/env bats
setup() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export SECURITY_TMP="$(mktemp -d)"
    export CALL_LOG="$SECURITY_TMP/calls"
    : > "$CALL_LOG"
}
teardown() { rm -rf "$SECURITY_TMP"; }

@test "security: permanent removal refuses untrusted ancestor links" {
    mkdir -p "$SECURITY_TMP/real"
    printf 'protected' > "$SECURITY_TMP/real/marker"
    ln -s "$SECURITY_TMP/real" "$SECURITY_TMP/alias"
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; safe_remove "$SECURITY_TMP/alias/marker" true'
    [ "$status" -ne 0 ]
    [ "$(cat "$SECURITY_TMP/real/marker")" = protected ]
}

@test "security: privileged deletion never invokes sudo" {
    printf 'protected' > "$SECURITY_TMP/marker"
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; sudo() { printf "%s\n" "$*" >> "$CALL_LOG"; }; safe_sudo_remove "$SECURITY_TMP/marker"'
    [ "$status" -ne 0 ]
    [ ! -s "$CALL_LOG" ]
    [ "$(cat "$SECURITY_TMP/marker")" = protected ]
}

@test "security: failed network detection does not reset system state" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; route() { return 1; }; dscacheutil() { return 1; }; sudo() { printf "%s\n" "$*" >> "$CALL_LOG"; }; opt_network_stack_optimize'
    [ "$status" -ne 0 ]
    [ ! -s "$CALL_LOG" ]
}

@test "security: bluetooth and permission tasks are unavailable even directly" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/optimize/tasks.sh"; sudo() { printf "%s\n" "$*" >> "$CALL_LOG"; }; system_profiler() { return 1; }; has_bluetooth_hid_connected() { return 1; }; needs_permissions_repair() { return 0; }; opt_bluetooth_reset || :; opt_disk_permissions_repair'
    [ "$status" -ne 0 ]
    [ ! -s "$CALL_LOG" ]
}

@test "security: normal user cleanup preserves Finder trash" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/clean/user.sh"; safe_clean() { :; }; _clean_recent_items() { :; }; _clean_mail_downloads() { :; }; start_section_spinner() { :; }; stop_section_spinner() { :; }; is_path_whitelisted() { return 1; }; osascript() { printf "%s\n" "$*" >> "$CALL_LOG"; echo 1; }; run_with_timeout() { shift; "$@"; }; DRY_RUN=false; clean_user_essentials'
    [ "$status" -eq 0 ]
    [ ! -s "$CALL_LOG" ]
}

@test "security: autofix cannot modify PAM" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/manage/autofix.sh"; has_sudo_session() { return 0; }; sudo() { printf "%s\n" "$*" >> "$CALL_LOG"; }; TOUCHID_NOT_CONFIGURED=true; perform_auto_fix'
    [ ! -s "$CALL_LOG" ]
}

@test "security: service cleanup cannot unload even an inferred orphan" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/clean/apps.sh"; safe_remove() { printf "%s\n" "$*" >> "$CALL_LOG"; return 1; }; find() { return 0; }; launchctl() { printf "%s\n" "$*" >> "$CALL_LOG"; }; sudo() { printf "%s\n" "$*" >> "$CALL_LOG"; }; clean_orphaned_system_services; clean_orphaned_launch_agents'
    [ "$status" -eq 0 ]
    [ ! -s "$CALL_LOG" ]
}

@test "security: temporary cleanup rejects a substituted symlink" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; stop_inline_spinner() { :; }; d=$(create_temp_dir); register_temp_dir "$d"; printf protected > "$SECURITY_TMP/marker"; rmdir "$d"; ln -s "$SECURITY_TMP" "$d"; cleanup_temp_files; test "$(cat "$SECURITY_TMP/marker")" = protected; rm "$d"'
    [ "$status" -eq 0 ]
}

@test "security: temporary cleanup preserves an identity replacement" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; stop_inline_spinner() { :; }; d=$(create_temp_dir); register_temp_dir "$d"; mv "$d" "$d.saved"; mkdir "$d"; printf protected > "$d/marker"; cleanup_temp_files; test "$(cat "$d/marker")" = protected; rm -rf "$d" "$d.saved"'
    [ "$status" -eq 0 ]
}

@test "security: system cleanup performs no privileged scan or mutation" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; source "$PROJECT_ROOT/lib/clean/system.sh"; sudo() { echo forbidden; }; safe_sudo_remove() { echo forbidden; }; safe_sudo_find_delete() { echo forbidden; }; clean_deep_system'
    [ "$status" -eq 0 ]
    [[ "$output" == *Skipped* ]]
    [[ "$output" != *forbidden* ]]
}

@test "security: created temporary files survive substitution tracking and are cleaned" {
    run bash -c 'source "$PROJECT_ROOT/lib/core/common.sh"; stop_inline_spinner() { :; }; f=$(create_temp_file); test -f "$f"; cleanup_temp_files; test ! -e "$f"'
    [ "$status" -eq 0 ]
}
