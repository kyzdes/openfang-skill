#!/usr/bin/env bash
# safe-restart.sh — restart the OpenFang daemon without the three traps that kill it.
#
#   1. `openfang start` runs in the FOREGROUND — it never daemonizes.
#   2. Piping it (e.g. `| head`) sends SIGPIPE and KILLS the daemon.
#   3. `nohup … & disown` is NOT enough: disown does not leave the systemd cgroup, so when
#      systemd-oomd kills the terminal scope the daemon dies with it. Verified the hard way:
#        app-gnome-Alacritty-4436.scope: Failed with result 'oom-kill'
#      We therefore start it as its OWN transient systemd SERVICE, which outlives the terminal.
#      NOT a --scope: a scope runs as a child of the calling shell and BLOCKS, which (since
#      `start` is foreground) hangs the caller and re-creates the very bug above.
#
# Also handles: the daemon may REWRITE custom_models.json on stop, so we snapshot first.
#
# DESTRUCTIVE — kills ~30 running agents and re-spawns them from disk. Any runtime change made
# via `agent set` is reverted, because agent.toml on disk wins over the DB at every boot.
#
# Usage:  OPENFANG_CONFIRM=1 ./safe-restart.sh
set -uo pipefail

OF_HOME="${OPENFANG_HOME:-$HOME/.openfang}"
BIN="$OF_HOME/bin/openfang"
LOG="$OF_HOME/daemon-start.log"
API="${OPENFANG_URL:-http://127.0.0.1:4200}"

if [ "${OPENFANG_CONFIRM:-0}" != "1" ]; then
  cat >&2 <<'EOF'
REFUSING TO RUN.

This restarts the OpenFang daemon: ~30 agents are killed and re-spawned, in-flight work is lost,
session_repair may drop leading assistant turns, and any `agent set` change is reverted (disk wins).

Restart only when something actually requires it — the model registry and config are cached at boot
and there is NO reload command. To inspect the install, use scripts/diagnose.sh (read-only).

Re-run with:  OPENFANG_CONFIRM=1 ./safe-restart.sh
EOF
  exit 2
fi

[ -x "$BIN" ] || { echo "✘ binary not found: $BIN" >&2; exit 1; }

echo "── 1/5  snapshot the model registry (the daemon may rewrite it on stop)"
if [ -f "$OF_HOME/custom_models.json" ]; then
  cp "$OF_HOME/custom_models.json" "$OF_HOME/custom_models.json.prestop"
  echo "     saved → custom_models.json.prestop"
fi

echo "── 2/5  stop"
"$BIN" stop 2>&1 | tail -2
sleep 2

if [ -f "$OF_HOME/custom_models.json.prestop" ]; then
  if ! cmp -s "$OF_HOME/custom_models.json" "$OF_HOME/custom_models.json.prestop"; then
    echo "     ⚠  the daemon REWROTE custom_models.json on stop."
    echo "        yours: custom_models.json.prestop   theirs: custom_models.json"
    echo "        restore with: cp custom_models.json.prestop custom_models.json"
    echo "        (not done automatically — review the diff first)"
  fi
fi

# Redactor: daemon-start.log contains the live Telegram bot token verbatim (in the getUpdates URL)
# and is mode 0664. NEVER print raw lines from it. Documented, not chmod'd — the user rotates it.
redact() { sed -E 's#bot[0-9]+:[A-Za-z0-9_-]+#bot<REDACTED>#g'; }

echo "── 3/5  start as a transient systemd user service (survives this terminal dying)"
systemctl --user reset-failed openfang 2>/dev/null || true   # --unit fails if the name is taken/failed
if command -v systemd-run >/dev/null 2>&1; then
  # NOTE: a shell redirect here would capture systemd-run's OWN output, not the daemon's —
  # the daemon runs detached and its stdout goes to the journal. VERIFIED. Use -p StandardOutput
  # so daemon-start.log actually gets written, otherwise every grep-the-log check below finds
  # nothing and you cannot tell "healthy" from "failed".
  systemd-run --user --unit="openfang" --collect \
    -p StandardOutput="truncate:$LOG" -p StandardError=inherit \
    "$BIN" start
  echo "     launched as transient systemd user service 'openfang'"
else
  echo "     ✘ systemd-run unavailable." >&2
  echo "       Do NOT fall back to bare nohup — it does not survive systemd-oomd." >&2
  echo "       Create a systemd --user unit instead. Aborting." >&2
  exit 1
fi

echo "── 4/5  wait for boot"
for i in $(seq 1 20); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$API/api/health" 2>/dev/null)"
  [ "$CODE" = "200" ] && break
  sleep 2
done

echo "── 5/5  verify"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$API/api/health" 2>/dev/null)"
if [ "$CODE" != "200" ]; then
  echo "     ✘ daemon did NOT come up (http=$CODE). Last log lines:" >&2
  tail -15 "$LOG" 2>/dev/null | redact | cut -c1-160 >&2
  exit 1
fi
echo "     ✔ daemon UP"
curl -s --max-time 3 "$API/api/health/detail" 2>/dev/null | head -c 300; echo

echo "     telegram bridge:"
grep -iE "Telegram bot .* connected|telegram channel bridge started" "$LOG" 2>/dev/null \
  | tail -2 | redact | cut -c1-140 | sed 's/^/       /' || echo "       ⚠ not found — check config"

echo "     embedding driver:"
grep -iE "Embedding driver configured|No embedding provider available" "$LOG" 2>/dev/null \
  | tail -1 | cut -c1-140 | sed 's/^/       /' || echo "       ⚠ not found"

echo
echo "Done. If the embedding line says 'No embedding provider available', memory recall silently"
echo "fell back to text search → see references/memory-embeddings.md"
