#!/bin/bash
DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
"$DIR/runtime/node" "$DIR/packaging/macos/service.mjs" uninstall
RESULT=$?
read -r -p "Press Return to close..."
exit "$RESULT"
