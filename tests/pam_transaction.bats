#!/usr/bin/env bats
@test "PAM transaction isolation and rollback matrix" {
 run python3 "$BATS_TEST_DIRNAME/pam_transaction_test.py"
 [ "$status" -eq 0 ]
}
@test "production PAM entry is closed without sudo" {
 run bash -c 'source "$1/lib/manage/pam_transaction.sh"; sudo() { exit 99; }; apply_touchid_transaction enable' _ "$BATS_TEST_DIRNAME/.."
 [ "$status" -eq 1 ]; [[ "$output" == *"VM acceptance"* ]]
}
