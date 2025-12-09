#!/bin/bash
# NatSpec Documentation Coverage Check
#
# Validates that all public/external functions have either @notice or @inheritdoc tags.
# Used by CI to enforce documentation standards defined in CONTRIBUTING.md.
#
# Exit codes:
#   0 - All functions properly documented
#   1 - Found undocumented functions

set -e

echo "Checking for undocumented functions..."

HAS_ISSUES=0

# Find all Solidity files (excluding vendor and deprecated interfaces)
while IFS= read -r file; do
  # Skip files with @custom:ported-from tag (ported code keeps original documentation style)
  if grep -q "@custom:ported-from" "$file"; then
    continue
  fi

  # Extract function signatures with line numbers
  # Process each line without using a subshell (to avoid variable isolation)
  while IFS=: read -r line_num line_content; do
    # Skip if no match
    if [ -z "$line_num" ]; then
      continue
    fi

    # Get the 30 lines before the function (where NatSpec should be)
    # Increased from 10 to accommodate comprehensive documentation blocks
    context_start=$((line_num - 30))
    if [ $context_start -lt 1 ]; then
      context_start=1
    fi

    # Extract the context and check for @notice OR @inheritdoc (both are valid)
    context=$(sed -n "${context_start},${line_num}p" "$file")

    # Check if either @notice or @inheritdoc exists
    if ! echo "$context" | grep -qE "@notice|@inheritdoc"; then
      echo "❌ Missing @notice/@inheritdoc: $file:$line_num"
      echo "   Function: $(echo "$line_content" | sed 's/^\s*//')"
      HAS_ISSUES=1
    fi
  done < <(grep -n "^\s*function\s.*\(public\|external\)" "$file" || true)
done < <(find src -name "*.sol" -not -path "*/vendor/*" -not -path "*/interfaces/deprecated/*")

if [ $HAS_ISSUES -eq 1 ]; then
  echo ""
  echo "⚠️  Found functions without @notice or @inheritdoc tags"
  echo "Please add NatSpec documentation following CONTRIBUTING.md (NatSpec section)"
  exit 1
fi

echo "✅ All public/external functions have @notice or @inheritdoc"
exit 0
