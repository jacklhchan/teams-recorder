#!/bin/bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ ! -d "$ROOT" ]]; then
  echo "Repository root does not exist: $ROOT" >&2
  exit 2
fi

APPLICATION_SERVICES='Application''Services'
AX_UI_ELEMENT='AX''UIElement'
AX_IS_PROCESS_TRUSTED='AX''IsProcessTrusted'
AX_OBSERVER='AX''Observer'
AX_VALUE='AX''Value'
K_AX='k''AX'
PATTERN="${APPLICATION_SERVICES}|${AX_UI_ELEMENT}[A-Za-z0-9_]*|${AX_IS_PROCESS_TRUSTED}[A-Za-z0-9_]*|${AX_OBSERVER}[A-Za-z0-9_]*|${AX_VALUE}[A-Za-z0-9_]*|${K_AX}[A-Za-z0-9_]+"
TARGETS=("Sources" "Driver" "scripts" "Config" "Package.swift")

check_file() {
  local file="$1"
  local relative_file
  local symbol

  symbol="$(/usr/bin/grep -Eo "$PATTERN" "$file" | /usr/bin/head -n 1 || true)"
  if [[ -n "$symbol" ]]; then
    relative_file="${file#"$ROOT/"}"
    echo "Accessibility API prohibited: $relative_file: $symbol" >&2
    exit 1
  fi
}

for target in "${TARGETS[@]}"; do
  path="$ROOT/$target"
  [[ -e "$path" ]] || continue

  if [[ -f "$path" ]]; then
    check_file "$path"
  else
    while IFS= read -r file; do
      check_file "$file"
    done < <(/usr/bin/find "$path" -type f -print | LC_ALL=C /usr/bin/sort)
  fi
done

echo "Accessibility API audit passed."
