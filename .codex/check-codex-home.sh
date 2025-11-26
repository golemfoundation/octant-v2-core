#!/usr/bin/env bash
# Query CODEX_HOME directory

CODEX_HOME_DEFAULT="$HOME/.codex"
CODEX_HOME_ACTUAL="${CODEX_HOME:-$CODEX_HOME_DEFAULT}"

echo "CODEX_HOME environment variable: ${CODEX_HOME:-<not set>}"
echo "Effective CODEX_HOME: $CODEX_HOME_ACTUAL"
echo ""

if [ -d "$CODEX_HOME_ACTUAL" ]; then
    echo "Directory exists: $CODEX_HOME_ACTUAL"
    echo "Contents:"
    ls -la "$CODEX_HOME_ACTUAL"
else
    echo "Directory does not exist: $CODEX_HOME_ACTUAL"
fi

echo ""
if [ -f "$CODEX_HOME_ACTUAL/config.toml" ]; then
    echo "config.toml found:"
    cat "$CODEX_HOME_ACTUAL/config.toml"
else
    echo "No config.toml found in $CODEX_HOME_ACTUAL"
fi

