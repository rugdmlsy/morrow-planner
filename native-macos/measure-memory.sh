#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/native-macos/build/Morrow Planner.app/Contents/MacOS/Morrow Planner"
DATA_FILE="${1:-}"
WAIT_SECONDS="${TODO_MEMORY_WAIT_SECONDS:-7}"

if [[ ! -x "$BIN" ]]; then
  echo "Morrow Planner.app is not built; run ./native-macos/build.sh first." >&2
  exit 1
fi

for mode in list edit preview; do
  stdout_file="$(mktemp -t todo-memory-stdout)"
  stderr_file="$(mktemp -t todo-memory-stderr)"

  if [[ -n "$DATA_FILE" ]]; then
    TODO_DATA_FILE="$DATA_FILE" TODO_BENCHMARK_MODE="$mode" "$BIN" >"$stdout_file" 2>"$stderr_file" &
  else
    TODO_BENCHMARK_MODE="$mode" "$BIN" >"$stdout_file" 2>"$stderr_file" &
  fi
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true' EXIT
  sleep "$WAIT_SECONDS"

  if ! kill -0 "$pid" 2>/dev/null; then
    echo "$mode: application exited before measurement" >&2
    cat "$stderr_file" >&2
    exit 1
  fi

  footprint="$(/usr/bin/footprint "$pid" 2>/dev/null | awk '/phys_footprint:/{print $2 " " $3; exit}')"
  rss_kb="$(ps -p "$pid" -o rss= | tr -d ' ')"
  cpu="$(ps -p "$pid" -o %cpu= | tr -d ' ')"
  printf '%-7s footprint=%-8s rss=%7s KB cpu=%s%%\n' "$mode" "$footprint" "$rss_kb" "$cpu"

  kill "$pid"
  wait "$pid" 2>/dev/null || true
  trap - EXIT
  rm -f "$stdout_file" "$stderr_file"
done
