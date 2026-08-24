#!/usr/bin/env bash
# Export amaran BLE mesh credentials from the amaran Desktop app.
#
# RUN THIS ON THE MAC (or Windows box, under Git Bash) that has amaran Desktop
# installed and paired with your lights — not on the Linux machine. It reads the
# app's SQLite database and writes a lights.json for the amaran BLE daemon.
#
#   ./amaran-export-keys.sh [output-path]
#
# The output contains your mesh network key and application key. Anyone holding
# them can drive your lights, so the file is written 0600 and should be moved
# over a private channel (scp), never pasted into a chat or committed.

set -euo pipefail

OUT="${1:-lights.json}"

die() { echo "amaran-export-keys: $*" >&2; exit 1; }

command -v sqlite3 >/dev/null || die "sqlite3 not found. On macOS it ships with the OS; otherwise install it."

find_db() {
  local candidates=(
    "$HOME/Library/Application Support/amaran Desktop"
    "$HOME/Library/Application Support/amaran"
    "${APPDATA:-}/amaran Desktop"
    "${LOCALAPPDATA:-}/amaran Desktop"
  )
  local base
  for base in "${candidates[@]}"; do
    [[ -n $base && -d $base ]] || continue
    # The app keeps one directory per account; take the newest amaran.db.
    local hit
    hit=$(find "$base" -name "amaran.db" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || true)
    [[ -n $hit ]] && { echo "$hit"; return 0; }
  done
  return 1
}

DB="${AMARAN_DB:-$(find_db || true)}"
[[ -n $DB ]] || die "could not find amaran.db. Open amaran Desktop, pair your lights, then re-run. Set AMARAN_DB=/path/to/amaran.db to point at it directly."
echo "Reading $DB" >&2

# Work on a copy: the app keeps the database open, and a live WAL would
# otherwise make reads fail or return a stale snapshot.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp "$DB" "$TMP/amaran.db"
for suffix in -wal -shm; do
  [[ -f "$DB$suffix" ]] && cp "$DB$suffix" "$TMP/amaran.db$suffix"
done
DB="$TMP/amaran.db"

if ! sqlite3 "$DB" ".tables" | tr ' ' '\n' | grep -qx "mesh"; then
  echo "amaran-export-keys: no 'mesh' table — the app's schema has changed." >&2
  echo "Tables found:" >&2
  sqlite3 "$DB" ".tables" >&2
  die "please open an issue with the schema above (no key values)."
fi

KEYS=$(sqlite3 -separator '|' "$DB" "SELECT net_key, app_key FROM mesh LIMIT 1;")
NET_KEY="${KEYS%%|*}"
APP_KEY="${KEYS##*|}"
[[ -n $NET_KEY && -n $APP_KEY ]] || die "mesh table has no net_key/app_key. Pair at least one light in amaran Desktop first."

FIXTURES=$(sqlite3 -separator '|' "$DB" \
  "SELECT mac_address, node_address, name FROM fixtures WHERE node_address > 1 ORDER BY node_address;")
[[ -n $FIXTURES ]] || die "no fixtures found. Pair your lights in amaran Desktop first."

umask 077
{
  echo "{"
  echo "  \"netKey\": \"$(echo "$NET_KEY" | tr '[:lower:]' '[:upper:]')\","
  echo "  \"appKey\": \"$(echo "$APP_KEY" | tr '[:lower:]' '[:upper:]')\","

  # The relay hub is whichever fixture the daemon opens its BLE proxy
  # connection to; the rest of the mesh is reached through it. First one wins.
  RELAY=$(echo "$FIXTURES" | head -1 | cut -d'|' -f1 | tr '[:lower:]' '[:upper:]')
  echo "  \"relayHub\": \"$RELAY\","
  echo "  \"http\": { \"port\": 2708, \"host\": \"127.0.0.1\" },"
  echo "  \"lights\": ["

  FIRST=1
  while IFS='|' read -r mac address name; do
    [[ -n $mac ]] || continue
    key=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-8)
    [[ -n $key ]] || key="light$address"
    [[ $FIRST -eq 1 ]] || echo ","
    FIRST=0
    printf '    { "key": "%s", "name": "%s", "mac": "%s", "address": %s }' \
      "$key" "${name:-Light $address}" "$(echo "$mac" | tr '[:lower:]' '[:upper:]')" "$address"
  done <<< "$FIXTURES"

  echo
  echo "  ]"
  echo "}"
} > "$OUT"

chmod 600 "$OUT"
echo "Wrote $OUT ($(echo "$FIXTURES" | wc -l | tr -d ' ') lights)" >&2
echo "This file contains your mesh keys. Copy it privately, e.g.:" >&2
echo "  scp $OUT you@linux-box:~/amaran-BLE-control/lights.json" >&2
