#!/usr/bin/env bash
set -euo pipefail

# Aggressive-but-safe ingestion ramp controller for strfry.
# Canonical path expectation: /home/owner/strangesignal/forks/strfry-compressed

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRFRY_BIN="${STRFRY_BIN:-$ROOT_DIR/strfry}"
DB_DIR="${DB_DIR:-$ROOT_DIR/strfry-db}"
STATE_DIR="${STATE_DIR:-$ROOT_DIR/ops/ramp-state}"
SOURCE_FILE="${SOURCE_FILE:-$ROOT_DIR/ops/ramp-sources.txt}"
mkdir -p "$STATE_DIR"

WAVE_PARALLEL="${WAVE_PARALLEL:-3}"                 # bounded parallel wave size
WAVE_TIMEOUT_SEC="${WAVE_TIMEOUT_SEC:-3600}"         # max per relay sync
MAX_CONNECT_ERRORS="${MAX_CONNECT_ERRORS:-20}"       # rollback threshold
MAX_DUP_RATE_PCT="${MAX_DUP_RATE_PCT:-85}"           # rollback threshold

usage() {
  cat <<EOF
Usage:
  $0 score-sources
  $0 sync-wave [N]
  $0 kpi
  $0 milestones
  $0 promote [phase]
  $0 rollback [phase]

Env overrides:
  STRFRY_BIN, DB_DIR, SOURCE_FILE, STATE_DIR, WAVE_PARALLEL,
  WAVE_TIMEOUT_SEC, MAX_CONNECT_ERRORS, MAX_DUP_RATE_PCT
EOF
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required binary: $1" >&2; exit 1; }
}

read_total_events() {
  # Fast path: strfry scan count of IDs. Fallback to previous known total when binary is absent.
  if [[ -x "$STRFRY_BIN" ]]; then
    "$STRFRY_BIN" scan '{"limit":0}' 2>/dev/null | wc -l | tr -d ' '
  elif [[ -f "$STATE_DIR/kpi-prev-total.txt" ]]; then
    cat "$STATE_DIR/kpi-prev-total.txt"
  else
    echo 0
  fi
}

score_sources() {
  require_bin timeout
  [[ -f "$SOURCE_FILE" ]] || { echo "Missing source file: $SOURCE_FILE" >&2; exit 1; }

  local out="$STATE_DIR/source-scores.tsv"
  : > "$out"
  echo -e "relay\tconnect_ms\tstatus\tscore" >> "$out"

  while IFS= read -r relay; do
    [[ -z "$relay" || "$relay" =~ ^# ]] && continue
    local start_ms end_ms delta status score
    start_ms=$(date +%s%3N)
    if timeout 20s "$STRFRY_BIN" sync "$relay" --dir down --filter '{"kinds":[1],"limit":5}' >/dev/null 2>&1; then
      status="ok"
      end_ms=$(date +%s%3N)
      delta=$((end_ms - start_ms))
      score=$((100000 / (delta + 500)))
    else
      status="fail"
      delta=20000
      score=0
    fi
    echo -e "${relay}\t${delta}\t${status}\t${score}" >> "$out"
  done < "$SOURCE_FILE"

  sort -t$'\t' -k4,4nr "$out" -o "$out"
  echo "Wrote source scores: $out"
}

sync_one() {
  local relay="$1"
  local logf="$STATE_DIR/sync-$(echo "$relay" | tr -cd '[:alnum:]').log"
  local rc=0
  timeout "${WAVE_TIMEOUT_SEC}s" "$STRFRY_BIN" sync "$relay" --dir down >"$logf" 2>&1 || rc=$?
  echo "$relay|$rc|$logf"
}

sync_wave() {
  local n="${1:-$WAVE_PARALLEL}"
  local scored="$STATE_DIR/source-scores.tsv"
  [[ -f "$scored" ]] || { echo "Run score-sources first." >&2; exit 1; }

  mapfile -t relays < <(awk -F'\t' 'NR>1 && $3=="ok" {print $1}' "$scored" | head -n "$n")
  [[ ${#relays[@]} -gt 0 ]] || { echo "No healthy relays to sync." >&2; exit 1; }

  local results="$STATE_DIR/last-wave-results.txt"
  : > "$results"
  for relay in "${relays[@]}"; do
    sync_one "$relay" &
  done
  wait

  # Reconstruct from logs deterministically
  for relay in "${relays[@]}"; do
    local logf="$STATE_DIR/sync-$(echo "$relay" | tr -cd '[:alnum:]').log"
    local rc=0
    grep -qiE 'timed out|error|fail|refused|reset' "$logf" && rc=1
    echo "$relay|$rc|$logf" >> "$results"
  done

  echo "Wave complete: $results"
}

kpi() {
  local now hr_prev_file="$STATE_DIR/kpi-prev-total.txt" csv="$STATE_DIR/kpi-hourly.csv"
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local total prev delta_hr unique_min dup_rate lag connect_errors
  total=$(read_total_events)
  prev=0
  [[ -f "$hr_prev_file" ]] && prev=$(cat "$hr_prev_file")
  delta_hr=$(( total - prev ))
  (( delta_hr < 0 )) && delta_hr=0
  unique_min=$(( delta_hr / 60 ))

  # Heuristics: derive lag/connect errors from recent logs
  connect_errors=$( (grep -RihE 'refused|timed out|reset|tls|handshake' "$STATE_DIR"/*.log 2>/dev/null || true) | wc -l | tr -d ' ')
  lag="n/a"
  dup_rate="n/a"

  # If import log contains accepted/duplicate counts, compute dup rate.
  if grep -RihE 'duplicate|accepted' "$STATE_DIR"/*.log >/dev/null 2>&1; then
    local dup acc
    dup=$(grep -RihEo 'duplicate[s]?:?[[:space:]]*[0-9]+' "$STATE_DIR"/*.log 2>/dev/null | awk '{s+=$NF} END{print s+0}')
    acc=$(grep -RihEo 'accepted:?[[:space:]]*[0-9]+' "$STATE_DIR"/*.log 2>/dev/null | awk '{s+=$NF} END{print s+0}')
    if (( dup + acc > 0 )); then
      dup_rate=$(awk -v d="$dup" -v a="$acc" 'BEGIN{printf "%.2f", (d/(d+a))*100}')
    fi
  fi

  [[ -f "$csv" ]] || echo "timestamp,total,delta_hr,unique_min,dup_rate_pct,lag,connect_errors" > "$csv"
  echo "$now,$total,$delta_hr,$unique_min,$dup_rate,$lag,$connect_errors" >> "$csv"
  echo "$total" > "$hr_prev_file"

  echo "timestamp,total,delta_hr,unique_min,dup_rate_pct,lag,connect_errors"
  tail -n 1 "$csv"
}

milestones() {
  local total deltas_h
  total=$(read_total_events)
  deltas_h=$(tail -n 6 "$STATE_DIR/kpi-hourly.csv" 2>/dev/null | awk -F',' 'NR>1 {s+=$3;c++} END{if(c==0)print 0; else print int(s/c)}')
  (( deltas_h <= 0 )) && deltas_h=50000

  printf "Current total: %s\n" "$total"
  for m in 10000000 25000000 50000000 100000000; do
    if (( total >= m )); then
      printf "%9d: reached\n" "$m"
    else
      local remain eta_h eta_low eta_high
      remain=$((m-total))
      eta_h=$(( (remain + deltas_h - 1) / deltas_h ))
      eta_low=$(( eta_h * 80 / 100 ))
      eta_high=$(( eta_h * 130 / 100 ))
      printf "%9d: ETA %dh (%dh-%dh) at %d ev/hr\n" "$m" "$eta_h" "$eta_low" "$eta_high" "$deltas_h"
    fi
  done
}

promote() {
  local phase="${1:-phase-unknown}"
  cat <<EOF
PROMOTE ${phase}
1) cp "$ROOT_DIR/strfry.conf" "$ROOT_DIR/strfry.conf.${phase}.bak"
2) export STRFRY_EVENT_PAYLOAD_ZSTD_LEVEL=3
3) systemctl reload strfry || kill -HUP \$(pidof strfry)
4) $0 kpi
5) gate: connect_errors <= ${MAX_CONNECT_ERRORS} and dup_rate <= ${MAX_DUP_RATE_PCT}%
EOF
}

rollback() {
  local phase="${1:-phase-unknown}"
  cat <<EOF
ROLLBACK ${phase}
1) cp "$ROOT_DIR/strfry.conf.${phase}.bak" "$ROOT_DIR/strfry.conf"
2) unset STRFRY_EVENT_PAYLOAD_ZSTD_LEVEL
3) systemctl restart strfry || pkill -f "$STRFRY_BIN relay" && "$STRFRY_BIN" relay &
4) freeze new sync waves for 60m
5) $0 kpi
EOF
}

cmd="${1:-}"
case "$cmd" in
  score-sources) score_sources ;;
  sync-wave) shift; sync_wave "${1:-$WAVE_PARALLEL}" ;;
  kpi) kpi ;;
  milestones) milestones ;;
  promote) shift; promote "${1:-phase}" ;;
  rollback) shift; rollback "${1:-phase}" ;;
  *) usage; exit 1 ;;
esac
