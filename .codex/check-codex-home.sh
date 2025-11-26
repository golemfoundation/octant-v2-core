#!/usr/bin/env bash
# Discover where Codex looks for configuration by default

echo "=== CODEX_HOME Discovery ==="
echo ""
echo "CODEX_HOME env var: ${CODEX_HOME:-<not set>}"
echo ""

echo "=== Checking potential config locations ==="
LOCATIONS=(
    "$HOME/.codex"
    "$HOME/.config/codex"
    "/etc/codex"
    "./.codex"
    "./codex"
)

for loc in "${LOCATIONS[@]}"; do
    if [ -d "$loc" ]; then
        echo "[EXISTS]  $loc"
        if [ -f "$loc/config.toml" ]; then
            echo "          ^ has config.toml"
        fi
    else
        echo "[MISSING] $loc"
    fi
done

echo ""
echo "=== Codex CLI config (if available) ==="
if command -v codex &> /dev/null; then
    codex config 2>/dev/null || codex --version 2>/dev/null || echo "codex command found but no config subcommand"
else
    echo "codex CLI not in PATH"
fi

echo ""
echo "=== Environment ==="
env | grep -i codex || echo "No CODEX env vars found"

