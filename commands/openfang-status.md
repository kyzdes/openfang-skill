---
allowed-tools: Bash(openfang status:*), Bash(openfang health:*), Bash(openfang agent list:*), Bash(curl:*), Bash(grep:*), Bash(sqlite3:*), Bash(tail:*), Bash(pgrep:*), Bash(export:*), Read
description: One-glance OpenFang health — daemon, agents, model, recent errors, token spend. Read-only.
disable-model-invocation: false
---

Give the user a one-glance health picture of the OpenFang install. **This command is strictly
read-only** — never start, stop, restart, or reconfigure anything here.

⚠️ **"Read-only" ≠ "free".** `openfang status` is **only** safe once `health` returns `200`. With the
daemon **down** it boots a full in-process kernel and writes **+9 irreversible rows** to the
hash-chained `audit_entries` trail. **Step 3 below is guarded — do not un-guard it, and do not
"just check with `status`" when step 1 says `000`.**

🔴 **`daemon-start.log` is world-readable and contains the live Telegram bot token verbatim.** Every
grep of it below goes through `redact`. Do not remove it. (Documented, not chmod'd — the user
rotates the token himself.)

Run these and report. Every command is bounded; keep it that way.

```bash
export PATH="$HOME/.openfang/bin:$PATH"
LOG="$HOME/.openfang/daemon-start.log"
redact() { sed -E 's#bot[0-9]+:[A-Za-z0-9_-]+#bot<REDACTED>#g'; }

# 1. Is the daemon up?  000 = DOWN.  THE ONLY FREE LIVENESS PROBE.
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:4200/api/health)"
echo "health_http=$CODE"

# 2 & 3. Detail + kernel status — ONLY when the daemon is up (then they are plain GETs, not a
#        kernel boot). GUARDED ON PURPOSE: see the audit-cost warning above.
if [ "$CODE" = "200" ]; then
  curl -s --max-time 5 http://127.0.0.1:4200/api/health/detail
  openfang status 2>&1 | head -20
else
  echo "daemon DOWN — skipping \`status\` (it would write +9 irreversible audit rows)."
  echo "offline substitutes (free):"
  ls -1 "$HOME/.openfang/agents" | wc -l                                  # agent count
  sqlite3 -readonly "$HOME/.openfang/data/openfang.db" \
    "SELECT COUNT(*) FROM audit_entries;"                                 # audit total (only grows)
  grep -E '^(model|provider)' "$HOME/.openfang/config.toml" | head -4     # default model/provider
fi

# 4. Recent errors (bounded). NOTE: total inference failure logs at WARN — `grep ERROR` finds
#    NOTHING. `Fallback driver failed` is the real test; `Agent error for` proves nothing by absence.
grep -acE "Fallback driver failed" "$LOG" 2>/dev/null
grep -aiE "Agent error|LLM driver error|Boot failed" "$LOG" 2>/dev/null | tail -5 | redact

# 5. Crash-recovery loop (upstream #1252) — is it churning?
grep -aicE "marked as Crashed|Auto-recovering" "$LOG" 2>/dev/null

# 6. Token spend today
sqlite3 -readonly "$HOME/.openfang/data/openfang.db" \
  "SELECT substr(timestamp,1,10) d, COUNT(*) calls, SUM(input_tokens) in_tok, SUM(output_tokens) out_tok
   FROM usage_events GROUP BY d ORDER BY d DESC LIMIT 3;" 2>/dev/null
```

⚠️ **If the log is stale, step 4/5 counts describe a PAST session, not now.** `daemon-start.log` only
keeps being written if the daemon was started the sanctioned way (`-p StandardOutput="truncate:…"`).
Check freshness with `stat -c %y "$LOG"` before presenting counts as current.

## How to report it

Lead with the answer: **daemon UP or DOWN**, then the numbers. Keep it to a short table plus at most
two sentences.

Interpret, do not just dump:

- **`health_http=000`** → the daemon is DOWN. Say so first. Do not start it — that is
  `/openfang-restart`, and it needs the user's explicit go-ahead. **And do not stop there:** a down
  daemon explains the *silence*, but if `Fallback driver failed` (step 4) is non-zero the model chain
  was **also** dead, and a restart will not fix that. Report both faults.
- **`openfang status` prints `Data dir: ?`** → known cosmetic bug. Do not mention it as a problem.
- **`marked as Crashed` / `Auto-recovering` counts > 0** → upstream #1252, the hardcoded 60 s
  heartbeat. Real, and it fires an LLM call per recovery. Worth flagging if the count is climbing.
- **`Agent error for <uuid>`** → the LLM call failed, *not* a channel or agent problem. Point at
  `references/models-providers.md`.
- **Input:output token ratio wildly lopsided** (this install has seen 112:1) → autonomous ticks
  burning quota on "no actionable items". Point at `references/automation.md` and upstream #1206.
- **`status` says `Agents: 30`** → normal. All bundled templates auto-spawn at boot. Idle ones
  emitting `Agent is unresponsive` is cosmetic.

If anything looks wrong, name the reference file that covers it rather than improvising a fix.
