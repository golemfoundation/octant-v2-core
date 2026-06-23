#!/usr/bin/env bash

set -euo pipefail

mkdir -p reports

report_path="reports/slither.txt"

if ! command -v slither >/dev/null 2>&1; then
  echo "slither not found on PATH" | tee "$report_path"
  exit 127
fi

set +e
slither . --disable-color 2>&1 | tee "$report_path"
slither_status=${PIPESTATUS[0]}
set -e

exit "$slither_status"
