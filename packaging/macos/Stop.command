#!/bin/bash
DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
"$DIR/runtime/node" "$DIR/packaging/macos/service.mjs" stop
RESULT=$?
if [ "$RESULT" -ne 0 ]; then read -r -p "Press Return to close..."; fi
exit "$RESULT"
