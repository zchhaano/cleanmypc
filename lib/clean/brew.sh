#!/bin/bash
# Third-party cleanup can delete installed dependencies and is not confined to user caches.
clean_homebrew() {
    printf '%s\n' "Skipped: external-tool deletion is disabled by the Atlas safety policy."
}
