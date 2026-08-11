#!/usr/bin/env bash

# Keep the suite runnable by the Bash 3.2 shipped with macOS.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

bash "$SCRIPT_DIR/test_cjman.sh" || exit $?

if ! command -v node >/dev/null 2>&1 ||
    ! node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>18||(a===18&&b>=1)?0:1)' \
        >/dev/null 2>&1; then
    printf '%s\n' 'error: Node.js 18.1 or newer is required for metadata tests.' >&2
    exit 1
fi

exec node --test "$SCRIPT_DIR/test_formal_metadata.mjs"
