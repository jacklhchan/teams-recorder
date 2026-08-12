#!/bin/bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FIND_BIN="/usr/bin/find"
GREP_BIN="/usr/bin/grep"
SORT_BIN="/usr/bin/sort"

if [[ ! -d "$ROOT" ]]; then
  echo "Repository root does not exist: $ROOT" >&2
  exit 2
fi

if [[ "${ACCESSIBILITY_AUDIT_TEST_MODE:-}" == "1" && "${ACCESSIBILITY_AUDIT_ALLOW_TOOL_OVERRIDES:-}" == "1" ]]; then
  FIND_BIN="${ACCESSIBILITY_AUDIT_FIND_BIN:-$FIND_BIN}"
  GREP_BIN="${ACCESSIBILITY_AUDIT_GREP_BIN:-$GREP_BIN}"
  SORT_BIN="${ACCESSIBILITY_AUDIT_SORT_BIN:-$SORT_BIN}"
fi

TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/accessibility-api-audit.XXXXXX")" || {
  echo "Accessibility API audit error: could not create temporary manifest directory" >&2
  exit 2
}
trap '[[ -n "${TEMP_DIR:-}" ]] && /bin/rm -rf "$TEMP_DIR"' EXIT

APPLICATION_SERVICES='Application''Services'
AX_UI_ELEMENT='AX''UIElement'
AX_IS_PROCESS_TRUSTED='AX''IsProcessTrusted'
AX_OBSERVER='AX''Observer'
AX_VALUE='AX''Value'
K_AX='k''AX'
PATTERN="${APPLICATION_SERVICES}|${AX_UI_ELEMENT}[A-Za-z0-9_]*|${AX_IS_PROCESS_TRUSTED}[A-Za-z0-9_]*|${AX_OBSERVER}[A-Za-z0-9_]*|${AX_VALUE}[A-Za-z0-9_]*|${K_AX}[A-Za-z0-9_]+"
TARGETS=("Sources" "Driver" "scripts" "Config" "Package.swift")
FILES_FOUND=0

fail() {
  echo "Accessibility API audit error: $1" >&2
  exit 2
}

check_file() {
  local file="$1"
  local grep_status
  local matches
  local relative_file
  local symbol

  if matches="$("$GREP_BIN" -Eo "$PATTERN" "$file")"; then
    symbol="${matches%%$'\n'*}"
  else
    grep_status=$?
    if [[ "$grep_status" -eq 1 ]]; then
      return
    fi
    fail "grep failed for ${file#"$ROOT/"} (exit $grep_status)"
  fi

  if [[ -n "$symbol" ]]; then
    relative_file="${file#"$ROOT/"}"
    echo "Accessibility API prohibited: $relative_file: $symbol" >&2
    exit 1
  fi
}

for target in "${TARGETS[@]}"; do
  path="$ROOT/$target"
  [[ -e "$path" ]] || continue

  manifest="$TEMP_DIR/${target//\//_}.manifest"

  if [[ -f "$path" ]]; then
    if ! printf '%s\n' "$path" > "$manifest"; then
      fail "could not write manifest for $target"
    fi
  else
    unsorted_manifest="$manifest.unsorted"
    if ! "$FIND_BIN" "$path" -type f -print > "$unsorted_manifest"; then
      fail "find failed for $target"
    fi
    if ! LC_ALL=C "$SORT_BIN" "$unsorted_manifest" > "$manifest"; then
      fail "sort failed for $target"
    fi
  fi

  while true; do
    if IFS= read -r file; then
      FILES_FOUND=$((FILES_FOUND + 1))
      check_file "$file"
    else
      read_status=$?
      if [[ "$read_status" -eq 1 ]]; then
        break
      fi
      fail "could not read manifest for $target (exit $read_status)"
    fi
  done < "$manifest"
done

if [[ "$FILES_FOUND" -eq 0 ]]; then
  fail "no production files found under $ROOT"
fi

echo "Accessibility API audit passed."
