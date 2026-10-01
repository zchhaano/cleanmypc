#!/usr/bin/env bats
setup() {
    export SYNC_ROOT="$(mktemp -d)"
    export REAL_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    mkdir -p "$SYNC_ROOT/scripts/atlas" "$SYNC_ROOT/bin" "$SYNC_ROOT/Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/Resources/MoleRuntime/bin"
    printf 'bin/demo.sh\n' > "$SYNC_ROOT/scripts/atlas/mole-runtime-files.txt"
    printf 'echo fresh\n' > "$SYNC_ROOT/bin/demo.sh"
    cp "$SYNC_ROOT/bin/demo.sh" "$SYNC_ROOT/Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/Resources/MoleRuntime/bin/demo.sh"
}
teardown() { rm -rf "$SYNC_ROOT"; }
@test "runtime parity detects content drift without writing" {
    printf 'echo stale\n' > "$SYNC_ROOT/Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/Resources/MoleRuntime/bin/demo.sh"
    run bash "$REAL_ROOT/scripts/atlas/sync-mole-runtime.sh" --check --root "$SYNC_ROOT"
    [ "$status" -eq 1 ]
    [ "$(cat "$SYNC_ROOT/Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/Resources/MoleRuntime/bin/demo.sh")" = 'echo stale' ]
}
@test "runtime parity detects missing or extra script" {
    rm "$SYNC_ROOT/Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/Resources/MoleRuntime/bin/demo.sh"
    run bash "$REAL_ROOT/scripts/atlas/sync-mole-runtime.sh" --check --root "$SYNC_ROOT"
    [ "$status" -eq 1 ]
    printf 'echo extra\n' > "$SYNC_ROOT/Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/Resources/MoleRuntime/bin/extra.sh"
    run bash "$REAL_ROOT/scripts/atlas/sync-mole-runtime.sh" --write --root "$SYNC_ROOT"
    [ "$status" -eq 1 ]
    [ -f "$SYNC_ROOT/Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/Resources/MoleRuntime/bin/extra.sh" ]
}
@test "runtime write synchronizes only manifest members" {
    run bash "$REAL_ROOT/scripts/atlas/sync-mole-runtime.sh" --write --root "$SYNC_ROOT"
    [ "$status" -eq 0 ]
    run bash "$REAL_ROOT/scripts/atlas/sync-mole-runtime.sh" --check --root "$SYNC_ROOT"
    [ "$status" -eq 0 ]
}
