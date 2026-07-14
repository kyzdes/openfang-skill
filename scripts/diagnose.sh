#!/usr/bin/env bash
# diagnose.sh — READ-ONLY health picture of an OpenFang install.
#
# Mutates nothing. Starts nothing. Every command is bounded (head/tail/LIMIT) so it cannot
# balloon the caller's memory — an unbounded command is what OOM-killed this machine twice.
#
# Usage: ./diagnose.sh
set -uo pipefail   # NOT -e: a missing daemon or tool must not abort the report

OF_HOME="${OPENFANG_HOME:-$HOME/.openfang}"
BIN="$OF_HOME/bin/openfang"
DB="$OF_HOME/data/openfang.db"
LOG="$OF_HOME/daemon-start.log"
API="${OPENFANG_URL:-http://127.0.0.1:4200}"

hr() { printf '\n─── %s %s\n' "$1" "$(printf '─%.0s' $(seq 1 $((60 - ${#1}))))"; }
have() { command -v "$1" >/dev/null 2>&1; }
# The daemon writes ANSI colour codes into the log file; strip them or the output is unreadable.
strip_ansi() { sed -E 's/\x1b\[[0-9;]*m//g'; }

echo "OpenFang diagnose — $(date '+%Y-%m-%d %H:%M:%S')"
echo "home=$OF_HOME  api=$API"

# ── 1. Daemon ────────────────────────────────────────────────────────────────
hr "DAEMON"
if [ ! -x "$BIN" ]; then
  echo "  ✘ binary not found or not executable: $BIN"
else
  echo "  version: $("$BIN" --version 2>&1 | head -1)"
fi

PID="$(pgrep -f "openfang start" 2>/dev/null | head -1)"
if [ -n "${PID:-}" ]; then
  echo "  process: PID $PID, up $(ps -o etime= -p "$PID" 2>/dev/null | tr -d ' ')"
  echo "  rss:     $(awk '/VmRSS/{printf "%.0f MB", $2/1024}' "/proc/$PID/status" 2>/dev/null)"
else
  echo "  process: not running"
fi

if have curl; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API/api/health" 2>/dev/null)"
  if [ "$CODE" = "200" ]; then
    echo "  http:    200 UP"
    curl -s --max-time 5 "$API/api/health/detail" 2>/dev/null | head -c 400; echo
  else
    echo "  http:    $CODE  ← 000 means DOWN (do not start it from here)"
  fi
else
  echo "  http:    curl not installed, skipped"
fi

if [ -f "$OF_HOME/daemon.json" ]; then
  echo "  daemon.json: present — if the daemon is DOWN this may be stale, but it does NOT block"
  echo "               start: the start guard validates the pid and removes it itself."
  echo "               Do NOT run 'doctor --repair' (it can regenerate config.toml from scratch)."
fi

# ── 2. Provider / model ──────────────────────────────────────────────────────
hr "PROVIDER / MODEL"
if [ -f "$OF_HOME/config.toml" ]; then
  grep -E '^(model|provider|base_url|api_key_env|embedding_model|embedding_provider)' \
    "$OF_HOME/config.toml" 2>/dev/null | sort -u | head -12 | sed 's/^/  /'
else
  echo "  ✘ config.toml not found at $OF_HOME/config.toml"
fi

# ── 3. Recent errors ─────────────────────────────────────────────────────────
hr "RECENT ERRORS (last 20)"
if [ -f "$LOG" ]; then
  grep -iE "Agent error|LLM driver error|Boot failed|Missing API key|error sending request|panic" \
    "$LOG" 2>/dev/null | tail -20 | strip_ansi | cut -c1-150 | sed 's/^/  /' || true
  grep -qiE "Agent error" "$LOG" 2>/dev/null && \
    echo "  ↑ 'Agent error for <uuid>' = the LLM call failed. Debug the MODEL, not the channel."
  PANICS="$(grep -oE 'total_panics[^0-9]*[0-9]+' "$LOG" 2>/dev/null | grep -oE '[0-9]+$' | sort -n | tail -1)"
  [ -n "${PANICS:-}" ] && echo "  agent panics recorded (supervisor high-water mark): $PANICS"
else
  echo "  no log at $LOG"
fi

# ── 4. Heartbeat / crash-recovery churn (upstream #1252) ─────────────────────
hr "HEARTBEAT / CRASH-RECOVERY  (upstream #1252)"
if [ -f "$LOG" ]; then
  echo "  'Agent is unresponsive' (cosmetic): $(grep -ic 'Agent is unresponsive' "$LOG" 2>/dev/null)"
  echo "  'marked as Crashed'     (REAL):     $(grep -ic 'marked as Crashed' "$LOG" 2>/dev/null)"
  echo "  'Auto-recovering'       (REAL):     $(grep -ic 'Auto-recovering' "$LOG" 2>/dev/null)"
  # heartbeat lines land in tui.log too — check both, not just daemon-start.log
  TS="$(grep -hoE 'timeout_secs=[0-9]+' "$LOG" "$OF_HOME/tui.log" 2>/dev/null | sort | uniq -c | head -5)"
  if [ -n "$TS" ]; then
    echo "  timeout_secs seen (daemon-start.log + tui.log):"
    echo "$TS" | sed 's/^/    /'
    echo "  (60 = the hardcoded value from #1252; each recovery fires an LLM call)"
  else
    echo "  timeout_secs: none in the current logs (they rotate/truncate on restart —"
    echo "                absence here is NOT evidence that #1252 is fixed)"
  fi
fi

# ── 5. Token spend ───────────────────────────────────────────────────────────
hr "TOKEN SPEND"
if ! have sqlite3; then
  echo "  sqlite3 not installed, skipped"
elif [ ! -f "$DB" ]; then
  echo "  db not found: $DB"
else
  echo "  by day:"
  sqlite3 "$DB" "SELECT substr(timestamp,1,10), COUNT(*), SUM(input_tokens), SUM(output_tokens)
                 FROM usage_events GROUP BY 1 ORDER BY 1 DESC LIMIT 5;" 2>/dev/null \
    | awk -F'|' '{printf "    %s  calls=%-5s in=%-9s out=%s\n",$1,$2,$3,$4}'
  echo "  by agent (top 5):"
  sqlite3 "$DB" "SELECT a.name, COUNT(*) FROM usage_events u JOIN agents a ON a.id=u.agent_id
                 GROUP BY a.name ORDER BY 2 DESC LIMIT 5;" 2>/dev/null \
    | awk -F'|' '{printf "    %-20s %s\n",$1,$2}'
  RATIO="$(sqlite3 "$DB" "SELECT CASE WHEN SUM(output_tokens)>0
                          THEN SUM(input_tokens)/SUM(output_tokens) ELSE -1 END FROM usage_events;" 2>/dev/null)"
  echo "  input:output ratio = ${RATIO}:1  (a huge ratio = autonomous ticks burning quota, #1206)"
fi

# ── 6. Embeddings ────────────────────────────────────────────────────────────
hr "EMBEDDINGS"
if have sqlite3 && [ -f "$DB" ]; then
  WITH="$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE embedding IS NOT NULL;" 2>/dev/null)"
  WITHOUT="$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE embedding IS NULL;" 2>/dev/null)"
  echo "  memories with embedding:    ${WITH:-?}"
  echo "  memories without embedding: ${WITHOUT:-?}   (old rows are NOT backfilled — expected)"
fi
if have curl; then
  OCODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:11434/api/version 2>/dev/null)"
  echo "  ollama http: ${OCODE}  $([ "$OCODE" = "200" ] && echo UP || echo 'DOWN → recall silently falls back to text search')"
fi
[ -f "$LOG" ] && grep -i "Embedding driver configured\|No embedding provider available" "$LOG" 2>/dev/null \
  | tail -1 | strip_ansi | cut -c1-150 | sed 's/^/  /'

# ── 7. Schedules (cost risk, #1206) ──────────────────────────────────────────
hr "SCHEDULES  (cost risk, upstream #1206)"
for f in "$OF_HOME"/agents/*/agent.toml; do
  [ -f "$f" ] || continue
  C="$(grep -oE 'cron *= *"[^"]+"' "$f" 2>/dev/null | head -1)"
  [ -n "$C" ] && printf '  %-20s %s\n' "$(basename "$(dirname "$f")")" "$C"
done
echo "  (\"every 5m\" = 288 LLM-backed runs/day)"

# ── 8. OOM history ───────────────────────────────────────────────────────────
hr "RECENT OOM KILLS"
if have journalctl; then
  journalctl --no-pager --since "-24 hours" 2>/dev/null \
    | grep -oE "Killed process [0-9]+ \([^)]+\)" | tail -5 | sed 's/^/  /' \
    || echo "  none in the last 24h"
else
  echo "  journalctl unavailable, skipped"
fi

hr "DONE"
echo "  Nothing was modified. To restart safely: scripts/safe-restart.sh (OPENFANG_CONFIRM=1)"
