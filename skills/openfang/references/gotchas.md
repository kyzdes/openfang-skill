# OpenFang v0.6.9 — Gotchas & Failure Modes

**Read this when:** anything about OpenFang misbehaves, before you run `start`/`stop`, before you
grep or script against the install, before you touch `custom_models.json` / `config.toml`, when the
daemon "dies for no reason", when the bill or the token count looks wrong, or when a CLI/DB/API
answer contradicts another. Read it **before** acting, not after — most entries below are
irreversible or expensive on the first wrong command.

Scope: OpenFang **v0.6.9** (`openfang 0.6.9`, last upstream `main` commit 2026-05-12 — the project
is **abandoned**; no fix is coming for anything marked UPSTREAM). Verified against the live install
at `/home/kyzdes/.openfang` on 2026-07-14.

Markers: **VERIFIED** = observed here, command + real output shown · **UPSTREAM** = from the repo /
issue tracker, not reproduced here · **SUSPECT** = evidence conflicts, resolution noted ·
**UNVERIFIED** = could not test, reason given.

---

## Check this first (triage)

Symptom → jump to entry.

| What you see | Go to |
|---|---|
| Machine froze / terminal vanished / OOM | [G1](#g1-recursive-grep-from-the-home-dir-ooms-the-machine), [G2](#g2-nohup--disown-does-not-survive-systemd-oomd--use-a-transient-systemd-service-not-a-scope) |
| Daemon died on its own, no error | [G2](#g2-nohup--disown-does-not-survive-systemd-oomd--use-a-transient-systemd-service-not-a-scope), [G3](#g3-openfang-start-is-foreground--piping-it-to-head-sigpipes-the-daemon-dead) |
| Your start command hung / never returned | [G2a](#g2a-systemd-run---user---scope-blocks--it-does-not-detach) |
| Started under `systemd-run`, but the log only says "Running as unit" | [G2b](#g2b-a-shell-redirect-on-systemd-run-captures-systemd-runs-own-output-not-the-daemons) |
| Daemon "gone" right after you ran a `\| head` | [G3](#g3-openfang-start-is-foreground--piping-it-to-head-sigpipes-the-daemon-dead) |
| A live Telegram token appeared in your terminal | [G3a](#g3a-the-telegram-bot-token-leaks-verbatim-into-daemon-startlog-which-is-0664) |
| Unexpected LLM spend / provider rate-limits | [G4](#g4-bundled-agents-ship-aggressive-schedules--288-runsday-from-ops-alone), [G5](#g5-heartbeat-marks-idle-agents-crashed-and-auto-recovers-them-forever), [G6](#g6-token-burn-is-1181-inputoutput--autonomous-tick-concluding-nothing-to-do) |
| Budget shows `0.0`, always | [G7](#g7-budget-enforcement-is-inert--every-cost_usd-is-00) |
| Edited `custom_models.json`, nothing changed | [G8](#g8-model-registry-is-cached-at-boot--no-reload-command-exists) |
| Your edit to `custom_models.json` disappeared | [G9](#g9-the-daemon-rewrites-custom_modelsjson-on-stop--your-edit-is-lost) |
| `config set` ate your comments / reordered the file | [G10](#g10-config-setunset-rewrite-the-file--comments-and-ordering-are-destroyed) |
| `agent set` reverted after restart | [G11](#g11-agent-toml-on-disk-differs-from-db-updating--disk-always-wins-runtime-edits-are-reverted) |
| A "read-only" command changed state | [G12](#g12-openfang-status-is-not-read-only--it-boots-a-kernel-and-writes-the-db) |
| 500 `single tool-calls at once` | [G13](#g13-minimax-m27-500s-on-parallel-tool-calls-and-there-is-no-parallel_tool_calls-knob) |
| `Missing API key: Set GROQ_API_KEY` | [G14](#g14-every-bundled-agent-hardcodes-groq_api_key--gemini_api_key-in-fallback_models) |
| NIM / nvidia connection errors flooding audit | [G15](#g15-the-last-resort-nim-fallback-is-unreachable-237-audit-rows) |
| `model_not_found` on a slashed model id | [G16](#g16-openai-compatible-custom-base_url-strips-the-namespace-from-slashed-model-ids) |
| Memory recall returns nothing / embeddings missing | [G17](#g17-embeddings--only-ollama-works-and-backfill-never-happens) |
| `WHERE source='conversation'` matches 0 rows | [G18](#g18-memoriessource-and-agentsstate-are-double-encoded-json-in-the-db) |
| DB says `suspended`, API says `Running` | [G19](#g19-agentsstate-in-the-db-is-permanently-suspended-and-never-written-back) |
| `doctor` says no API keys but the daemon works | [G20](#g20-doctor-is-blind-to-custom-providers-and-to-secretsenv) |
| `skill list` → "No skills installed" | [G21](#g21-skill-list-only-enumerates-user-skills--the-61-bundled-ones-are-invisible) |
| `/api/agents/` 404s but `/api/agents` works | [G22](#g22-trailing-slash-routes-404--but-the-slash-forms-are-the-literals-in-the-binary) |
| grep on `daemon-start.log` finds nothing | [G23](#g23-daemon-startlog-is-full-of-ansi-escapes--naive-greps-silently-miss) |
| `openfang start` refuses, stale daemon | [G24](#g24-stale-daemonjson-does-not-block-start--this-gotcha-was-wrong) (**retracted — it does not block**) |
| Config typo → everything defaults | [G25](#g25-a-config-parse-failure-degrades-to-defaults-silently) |
| Deleted workflow came back | [G26](#g26-a-deleted-workflow-reappears-after-restart) |
| Copied the `.db`, got a stale snapshot | [G27](#g27-wal-is-not-checkpointed-while-running--copying-db-alone-gives-a-stale-snapshot) |
| `openfang.db` readable by everyone | [G28](#g28-openfangdb-is-0644-world-readable-with-full-transcripts) |
| `--yolo` | [G29](#g29---yolo-auto-approves-shell_exec-for-all-30-agents-with-network) |

**Cost order:** G1–G2b destroy the machine or the daemon. G3a–G7 burn money or leak credentials.
G8–G23 burn hours. G24–G34 are traps and cosmetics.

---

## Tier 1 — destroys the machine or the daemon

### G1: Recursive grep from the home dir OOMs the machine

**Symptom:** the terminal window disappears; the machine locks up; afterwards:
```
Out of memory: Killed process 26229 (2.1.209) total-vm:17039272kB, anon-rss:11371344kB, ...
app-gnome-Alacritty-4436.scope: Failed with result 'oom-kill'.
```

**Root cause:** `/home/kyzdes` is **8.5 GB** (ollama models, two 259 MB Claude binaries, caches,
`.jsonl` transcripts). A recursive grep/find/glob from `.`, `~`, `/`, or the working directory
walks all of it, and the agent host's Grep tool (ugrep) **buffers the entire result set into
memory**. The machine has 15 GB total with ~3.7 GB already resident. This happened **twice today**
(11.4 GB and 13.6 GB anon-rss), each time killing the whole terminal scope.

**Fix:** always scope to `~/.openfang` (or one file) and always bound the output.
```bash
# WRONG — never do these
grep -r PATTERN .
find / -name X
Grep(pattern, path=".")

# RIGHT
grep -rl PATTERN /home/kyzdes/.openfang --include="*.toml" | head -20
Grep(pattern, path="/home/kyzdes/.openfang", head_limit=20)
```
Same rule for every other unbounded emitter — **bound stdout to ~1 MB**:
```bash
strings BIN | grep -E PAT | head -c 2000     # never bare `strings`; head -c, not head -n
objdump -d BIN | grep -E PAT | head -50      # NEVER bare `objdump -d` — emits GBs
journalctl --since today | tail -50          # never bare journalctl
sqlite3 DB "SELECT ... LIMIT 20"             # never SELECT * with no LIMIT
```
**`head -n` is not enough protection** when lines can be huge: a stripped 66 MB Rust binary has
single `strings` "lines" tens of KB long (all the channel adapter literals are one blob). Use
`head -c`.

**Evidence:** `journalctl --since today | grep -i oom | tail -20` → the two kills above, at
10:36:41 and 10:51:23, both `task_memcg=/user.slice/.../app-gnome-Alacritty-*.scope`.

**Marker:** VERIFIED (twice, by controlled experiment)

---

### G2: `nohup` + `disown` does **not** survive systemd-oomd — use a transient systemd service, not a scope

**Symptom:** the daemon, launched detached and backgrounded, dies anyway when something else in the
terminal eats RAM:
```
oom-kill:constraint=CONSTRAINT_NONE,...,task_memcg=/user.slice/user-1000.slice/user@1000.service/app.slice/app-gnome-Alacritty-4436.scope
app-gnome-Alacritty-4436.scope: Failed with result 'oom-kill'.
```

**Root cause:** **`disown` only removes the job from bash's job table. It does not move the process
out of the systemd cgroup.** The daemon stays inside `app-gnome-Alacritty-<pid>.scope`. When
systemd-oomd (or the kernel OOM killer) decides that scope is over budget, it kills **the whole
scope** — terminal, agent, and daemon together. `nohup` protects against SIGHUP, which is *not*
what kills you here.

**Fix:** put the daemon in its own cgroup, outside the terminal scope.
```bash
# One-shot, correct:
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start

# Better — a real unit that survives logout and restarts on failure.
# The unit does NOT exist on this box: `systemctl --user list-unit-files | grep -i openfang` → empty
# (VERIFIED). You must WRITE the file first — the two lines below error until you do.
cat > ~/.config/systemd/user/openfang.service <<'EOF'
[Service]
ExecStart=/home/kyzdes/.openfang/bin/openfang start
Restart=on-failure
MemoryMax=2G
EOF
systemctl --user daemon-reload && systemctl --user enable --now openfang
```
**Note `--unit=openfang` vs `--scope`:** the one-shot form above deliberately has **no `--scope`**.
A scope would block and defeat the whole point — see [G2a](#g2a-systemd-run---user---scope-blocks--it-does-not-detach).
Verify the daemon is no longer in the terminal's scope:
```bash
systemctl --user status openfang | head -5
cat /proc/$(pgrep -f 'openfang start' | head -1)/cgroup     # must NOT contain app-gnome-*.scope
```
**Do NOT use:** `nohup openfang start > log 2>&1 & disown`. That is exactly what was running when
the daemon was killed today.

**Evidence:** `journalctl --since today | grep -i oom-kill | tail -10` → the scope-level kill above;
the daemon (`nohup`+`disown`ed) died with it. Daemon is down now: `curl --max-time 3
http://127.0.0.1:4200/api/status` → exit 7, HTTP `000`.

**Marker:** VERIFIED

---

### G2a: `systemd-run --user --scope` **BLOCKS** — it does not detach

**Symptom:** you "fix" G2 by reaching for `--scope` (older revisions of this playbook said so;
**SKILL.md and every recipe now carry the correct service form — if you see `--scope` anywhere, it is
stale text, not an instruction**), and
your start command **never returns**. The agent turn hangs; when the harness or your shell gives up,
the daemon dies with it — reproducing the exact outage `--scope` was supposed to prevent.

**Root cause:** **a scope is not a service.** `systemd-run --user --scope` registers the *calling
shell's child* into a new cgroup and then runs it **in the foreground, as your child**. It does not
fork it under the systemd user manager. Combined with G3 (`openfang start` is foreground and never
exits), the call blocks forever, the daemon stays a descendant of your terminal, and it inherits
your `oom_score_adj` — so the scope-level OOM kill from G2 still reaches it. **Dropping `--scope`
is what makes systemd-run detach:** without it you get a *transient service*, forked into its own
unit by the user manager, returning immediately.

**Fix:** the transient-service form. Never `--scope` for a daemon.
```bash
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start
```

**Evidence:** controlled A/B with a 3-second no-op, this box, today:
```
$ /usr/bin/time -f "elapsed=%e" systemd-run --user --scope --quiet sleep 3
elapsed=3.02          # BLOCKED for the full 3s — ran as a child of the shell

$ /usr/bin/time -f "elapsed=%e" systemd-run --user --collect --quiet --unit=probe sleep 3
elapsed=0.01          # returned instantly — forked into its own unit
```
A 300× difference. `--scope` is not a detach mechanism at all.

**Marker:** VERIFIED (controlled experiment, both arms)

---

### G2b: A shell redirect on `systemd-run` captures **systemd-run's own output**, not the daemon's

**Symptom:** you launch correctly under `systemd-run`, then every log check comes back **empty** —
silently. `grep 'Fallback driver failed' ~/.openfang/daemon-start.log` → nothing. You conclude the
boot was clean. It was not; you are grepping the wrong file's contents.

**Root cause:** in `systemd-run … openfang start > ~/.openfang/daemon-start.log 2>&1`, the redirect
is applied by **your shell to `systemd-run`**, which is a *client* that hands the job to the user
manager and exits. The daemon's stdout belongs to the transient unit and goes to **journald**. So
the log file receives only systemd-run's one-line receipt:
```
Running as unit: openfang.service
```
Every subsequent grep-the-log verification then finds nothing and **reports success by finding
nothing** — the worst possible failure mode, because the check and the boot are decoupled.

**Fix:** let systemd own the redirect with `-p StandardOutput="truncate:…"`, or read journald instead.
```bash
# Option A — make the unit write the file the rest of the playbook greps:
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start

# Option B — leave output in journald and verify there (bounded!):
systemd-run --user --unit=openfang --collect /home/kyzdes/.openfang/bin/openfang start
journalctl --user -u openfang -n 40 --no-pager | sed 's/\x1b\[[0-9;]*m//g'
```
**`~` is NOT expanded inside `file:`** — systemd does no tilde expansion. Use an absolute path or
`$HOME` (which your shell expands before systemd-run sees it):
```
$ systemd-run --user -p StandardOutput="truncate:~/scratch-probe.log" /bin/echo hi
Failed to start transient service unit: Path ~/scratch-probe.log is not absolute
```
With an absolute path the file is written and contains the command's real output (`hi`) — VERIFIED.

**Consequence for the rest of the playbook:** `daemon-start.log` exists **only because** the old,
condemned `nohup … > log` form put it there. It is a *product of the launch method*, not a log the
daemon maintains. Adopt Option B and it is never written again — and every recipe keyed to it
(see `models-providers.md`, `channels.md`) goes quiet. Prefer Option A to keep them working.
See also [G23](#g23-daemon-startlog-is-full-of-ansi-escapes--naive-greps-silently-miss) — the file
is ANSI-laden, so a naive grep misses **twice** over.

**Marker:** VERIFIED (tilde rejection and absolute-path write reproduced here; the
"Running as unit:" capture reproduced by a fresh agent following the old recipe)

---

### G2c: `StandardOutput="file:"` does NOT truncate — `tail` then reads the PREVIOUS run

**Symptom:** you launch under `systemd-run` with `-p StandardOutput="file:…"`. The daemon comes up,
the log has content, the head looks fresh. Then `tail -20 ~/.openfang/daemon-start.log` shows lines
from a run that died **hours ago** — `OpenFang daemon stopped` at the very end, while the daemon is
demonstrably running. Every `tail`-based verification in this playbook silently reads stale data.

**Root cause:** systemd's `file:` mode opens the path **without O_TRUNC** and writes from offset 0.
It overwrites the beginning of the existing file in place and leaves everything past the new content
untouched. The log becomes a Frankenstein: fresh head, stale tail, unchanged size — which is exactly
why it looks healthy. `head` lies by omission; `tail` lies outright.

**Evidence (VERIFIED, 2026-07-14):** started the daemon at 16:13 local (14:13 UTC) with `file:`.
```bash
$ stat -c '%s %y' ~/.openfang/daemon-start.log
796982 2026-07-14 16:13:04          # mtime fresh — but size IDENTICAL to before the start

$ grep -aoE "^\S*2026-07-14T[0-9]{2}:" daemon-start.log | sed -E 's/.*T([0-9]{2}):/\1/' | sort | uniq -c
    125 07      # ← run from 07:xx UTC
   3036 08      # ← run that stopped at 08:36 UTC
     77 14      # ← the run I just started

$ tail -2 daemon-start.log
  OpenFang daemon stopped.          # from 08:36 UTC — while the daemon is UP
```
Three runs interleaved in one file. 77 fresh lines buried under 3161 stale ones.

**Fix:** use **`truncate:`**, not `file:`. It opens with O_TRUNC, so the log holds exactly one run —
which is what the rest of this playbook assumes when it says "tail the log".
```bash
-p StandardOutput="truncate:$HOME/.openfang/daemon-start.log"
```
Proved on this box: a 116-byte / 5-line file → 11 bytes / 1 line after one `truncate:` launch.

Use `append:` **only** if you deliberately want cross-boot history — but then every `tail` in this
playbook needs a timestamp filter, and see G23 (ANSI) and the UTC/local split before trusting it.

**Marker:** VERIFIED — reproduced both the bug and the fix on this machine.

**Related:** G2 (nohup/cgroup), G2a (`--scope` blocks), G2b (shell redirect captures the wrong
stream). All four are the same lesson: **the launch command has four independent ways to look like it
worked while breaking your verification.**

### G3: `openfang start` is **foreground** — piping it to `head` SIGPIPEs the daemon dead

**Symptom:** the daemon starts, prints boot logs, then dies the instant `head` closes the pipe. No
error is printed; it just ends.

**Root cause:** `start` runs in the foreground and streams logs to stdout. `head` exits after N
lines and closes the read end → the next write raises **SIGPIPE** → the daemon (not just the
logger) is killed. Same for `| grep -m1`, `| less` then `q`, and any short-circuiting consumer.

**Fix:** never pipe `start` into a truncating consumer. Redirect to a file, then read the file.
```bash
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start
sleep 8
sed -r 's/\x1b\[[0-9;]*m//g' /home/kyzdes/.openfang/daemon-start.log | tail -30   # read the FILE
```

**Evidence:** boot log is a foreground stream — `daemon-start.log` (784K) is exactly its stdout,
containing the whole kernel boot sequence rather than a detached log. Combine with G2: **launching
correctly requires both** a systemd scope *and* a file redirect.

**Marker:** VERIFIED (seed, reconfirmed by log shape)

---

## Tier 2 — burns money or leaks credentials

### G3a: The Telegram bot token leaks **verbatim** into `daemon-start.log`, which is 0664

**Symptom:** none — that is the point. Nothing warns you. The trap springs when *you* run one of the
playbook's own log recipes (`grep -i telegram ~/.openfang/daemon-start.log`) and a **live bot token**
lands on your screen, in your scrollback, and in your agent transcript.

**Root cause:** on every Telegram network error the daemon logs the **full request URL**, which
embeds the token by construction:
```
https://api.telegram.org/bot<TOKEN>/getUpdates
```
The token is stored correctly — `secrets.env` is **0600**. The daemon then copies it into a log that
is **0664, world-readable**. The careful half of the design is undone by the logging.

```
$ stat -c '%a %n' ~/.openfang/secrets.env ~/.openfang/daemon-start.log
600 /home/kyzdes/.openfang/secrets.env
664 /home/kyzdes/.openfang/daemon-start.log
```

**Fix — this is the user's to run, not yours.** Do **not** `chmod` anything under `~/.openfang`; the
owner is handling it. Your job is to *report* and to *not make it worse*:
1. **Rotate the token via @BotFather** (`/revoke`) if this log was ever shared, copied, backed up, or
   pasted — assume it was. Rotation is the only real remediation; a `chmod` does not un-leak it.
2. Then tighten: `chmod 600 ~/.openfang/daemon-start.log` — **owner runs this**.
3. Note the leak **recurs on every restart** while the log is recreated by the launch method. Per
   [G2b](#g2b-a-shell-redirect-on-systemd-run-captures-systemd-runs-own-output-not-the-daemons),
   launching via journald (Option B) stops writing this file at all — but journald is not a fix
   either, it just moves the secret.

**Never print the token.** Count it, never cat it. Redact by default:
```bash
# SAFE — count only, no value on screen:
grep -acE '[0-9]{8,10}:[A-Za-z0-9_-]{35}' ~/.openfang/daemon-start.log     # → 4

# SAFE — read the log with the token masked (use this instead of a bare grep):
sed -r 's/bot[0-9]{8,10}:[A-Za-z0-9_-]{35}/bot<REDACTED>/g' ~/.openfang/daemon-start.log \
  | sed -r 's/\x1b\[[0-9;]*m//g' | grep -i telegram | tail -20

# UNSAFE — what the playbook used to tell you to do:
grep -i telegram ~/.openfang/daemon-start.log     # prints the live token
```

**Evidence:** `grep -acE '[0-9]{8,10}:[A-Za-z0-9_-]{35}' ~/.openfang/daemon-start.log` → **4**
occurrences, today, against a 0664 file. A fresh agent independently hash-verified the logged value
against `secrets.env`: same token, still live.

**Marker:** VERIFIED (count and modes reproduced here; token value never printed)

---

### G4: Bundled agents ship aggressive schedules — 288 runs/day from `ops` alone

**Symptom:** steady LLM spend and provider rate-limits with nobody using the system.

**Root cause:** `agents/ops/agent.toml` ships `periodic = { cron = "every 5m" }` → **288
runs/day**. `health-tracker` is `every 1h` → 24/day. Upstream #1206: "sample agent configs ship
aggressive default schedules → unexpected LLM costs."

**Fix:** audit every schedule before first `start`, and delete the ones you did not ask for.
```bash
grep -rl "\[schedule\]" /home/kyzdes/.openfang/agents --include="*.toml"
grep -A3 "\[schedule\]" /home/kyzdes/.openfang/agents/ops/agent.toml
# To disable: stop the daemon, remove the [schedule] block from the agent.toml, start.
# Do NOT use `agent set` for this — see G11, disk wins on every boot anyway.
```

**Evidence:**
```
$ grep -rl "\[schedule\]" /home/kyzdes/.openfang/agents --include="*.toml"
/home/kyzdes/.openfang/agents/ops/agent.toml
/home/kyzdes/.openfang/agents/security-auditor/agent.toml
/home/kyzdes/.openfang/agents/orchestrator/agent.toml
/home/kyzdes/.openfang/agents/health-tracker/agent.toml

$ grep -A3 "\[schedule\]" /home/kyzdes/.openfang/agents/ops/agent.toml
[schedule]
periodic = { cron = "every 5m" }
```
**Correction to the seed:** it claims **5** scheduled agents including `assistant`. There are
exactly **4** — `assistant/agent.toml` has no `[schedule]` block
(`grep -A3 "schedule" .../assistant/agent.toml` → empty). Trust the grep.

**Marker:** VERIFIED · upstream #1206 UPSTREAM

---

### G5: Heartbeat marks idle agents Crashed and auto-recovers them forever

**Symptom:**
```
WARN openfang_kernel::heartbeat: Agent is unresponsive agent=assistant inactive_secs=90 timeout_secs=60
INFO openfang_kernel::kernel: Auto-recovering crashed agent (attempt 1/3) agent=ops attempt=1 max=3
```

**Root cause:** upstream #1252 — the heartbeat **ignores the configured `default_timeout_secs` and
hardcodes 60s** for some paths. An idle agent trips the 60s timeout, gets marked Crashed, and the
supervisor "recovers" it — which costs a provider call. The reporter measured **~570 provider
calls/day** from this alone.

**Distinguish cosmetic from expensive:**
- `Agent is unresponsive` **alone** → cosmetic, ignore.
- `... marked as Crashed for recovery` + `Auto-recovering crashed agent` → **real loop, real spend**.

**Fix:** no config fix exists (that *is* the bug — the knob is ignored). Reduce the surface:
remove `[schedule]` from agents you don't need (G4), and keep agent count low. Upstream 0.6.1
exempted *idle reactive* agents (#1102) but scheduled agents still trip it.

**Evidence:** both timeouts coexist in one boot, proving the config value is honored in one path and
ignored in another:
```
$ sed -r 's/\x1b\[[0-9;]*m//g' daemon-start.log | grep -oE "timeout_secs=[0-9]+" | sort | uniq -c
   1953 timeout_secs=180
     81 timeout_secs=60
$ grep -c "Agent is unresponsive" daemon-start.log   → 2034
$ grep -c "marked as Crashed"     daemon-start.log   → 28
$ grep -c "Auto-recovering"       daemon-start.log   → 28
```
28 real recovery cycles in a single session. **Correction to the seed:** the counts are 1953/81 (not
3134/139) and 2034 unresponsive lines — the seed's numbers were from an earlier, longer log.

**Marker:** VERIFIED (locally) · #1252 UPSTREAM

---

### G6: Token burn is 118:1 input/output — `[AUTONOMOUS TICK]` concluding "nothing to do"

**Symptom:** enormous input token counts, trivial output, no user-visible work.

**Root cause:** every scheduled tick re-sends the agent's full context (AGENTS.md, SOUL.md, TOOLS.md,
memory, session history) so the model can answer "No actionable items". The ratio is the tell.

**Fix:** kill the schedules (G4). There is no context-trimming knob that helps here; the compactor
only bounds session growth, not the per-tick system context.

**Evidence:**
```
$ sqlite3 openfang.db "SELECT SUM(input_tokens), SUM(output_tokens), SUM(cost_usd), COUNT(*) FROM usage_events;"
535106|4543|0.0|64
```
535,106 input vs 4,543 output = **117.8:1** across 64 calls.

**Marker:** VERIFIED

---

### G7: Budget enforcement is **inert** — every `cost_usd` is 0.0

**Symptom:** `/api/budget` returns all `0.0`; budget caps never fire; you find out about spend from
the provider's dashboard.

**Root cause:** `custom_models.json` has `input_cost_per_m = 0.0` for the gonka and NIM entries, so
every `usage_events.cost_usd` is computed as `0.0`, so `max_hourly_usd` / `max_daily_usd` /
`max_monthly_usd` / `alert_threshold` never trip. **The dollar budget system is decorative on this
install.**

**Fix:** the only enforcement that actually works is the per-agent token cap in `agent.toml`:
```toml
[resources]
max_llm_tokens_per_hour = 50000   # REAL — this one is enforced
```
Optionally populate real `input_cost_per_m` / `output_cost_per_m` in `custom_models.json` to make
cost accounting meaningful (stop the daemon first — G9).

**Evidence:** `SELECT SUM(cost_usd), COUNT(*) FROM usage_events;` → `0.0|64`. Every one of 64 real
calls priced at zero.

**Marker:** VERIFIED

---

### G8: Model registry is cached at boot — **no reload command exists**

**Symptom:** you edit `custom_models.json`, nothing changes, and no command makes it take effect.

**Root cause:** the catalog is read once at boot (`Model catalog: 334 models, 143 available from
configured providers (6 local)`) and held in memory. `config_reload` hot-reloads *config* (memory /
network / vault / api_listen), and even for provider keys it only promises "takes effect on next
driver init". The **model catalog is not in the reload path at all.**

**Fix:** restart is the only way. And it must be sequenced correctly — see G9.

**Evidence:** `openfang status 2>&1 | grep "Model catalog"` →
`Model catalog: 334 models, 143 available from configured providers (6 local)` — emitted during
boot, once. No `models reload` subcommand exists in the 40-command CLI surface.

**Marker:** VERIFIED

---

### G9: The daemon **rewrites** `custom_models.json` on stop → your edit is lost

**Symptom:** you edit the file while the daemon runs, restart, and your changes are gone.

**Root cause:** the daemon serializes its in-memory catalog back to disk on shutdown, clobbering
whatever you wrote.

**Fix — the only safe sequence:**
```bash
openfang stop                                             # 1. stop FIRST (skip if health is already 000)
cp ~/.openfang/custom_models.json.fixed ~/.openfang/custom_models.json   # 2. THEN copy your file in
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start                          # 3. THEN start (see G2/G3)
```
⚠️ **`file:` needs an ABSOLUTE path** — `file:daemon-start.log` is rejected by systemd, and `~` is
**not** expanded inside `file:` either. Use `$HOME`, as above.
Never edit-then-stop. Always stop-then-edit-then-start. Keep a `.fixed` copy so you can re-apply
after any accidental clobber — this install already does:
```
custom_models.json           49081  Jul 13 22:46
custom_models.json.bak-20260713  49143
custom_models.json.fixed     49081
```
(`.fixed` and the live file are byte-identical in size — the edit survived because the sequence was
followed.)

**Marker:** VERIFIED (seed; file layout consistent)

---

## Tier 3 — burns hours

### G10: `config set`/`unset` rewrite the file — comments and ordering are destroyed

**Symptom:** after one `openfang config set …`, every comment in `config.toml` is gone and the keys
have been reordered alphabetically.

**Root cause:** 0.6.0 introduced an **atomic config writer**: it parses to a TOML value, mutates, and
re-serializes. Comments are not part of the value model, so they are dropped. Serialization sorts
keys.

**Fix:** back up before any `config set`, and prefer editing the file by hand with the daemon
stopped.
```bash
cp /home/kyzdes/.openfang/config.toml /home/kyzdes/.openfang/config.toml.bak-$(date +%F)
```

**Evidence:** the live `config.toml` has **zero comments** and is alphabetically ordered within every
table (`api_listen`, then `[channels.telegram]` with `allowed_users` before `bot_token_env`, then
`[default_model]` with `api_key_env, base_url, model, provider`). Four `.bak*` files exist alongside
it — the scars of this gotcha.

**Note — seed schema correction:** the real key is **`[[fallback_providers]]`**, not
`[[fallback_models]]`, in `config.toml`. (`[[fallback_models]]` *is* correct inside an
`agent.toml` — the two schemas differ. Using the wrong one silently does nothing; see G25.)

**Marker:** VERIFIED

---

### G11: `Agent TOML on disk differs from DB, updating` — disk always wins, runtime edits are reverted

**Symptom:** on every boot, for all 30 agents:
```
INFO openfang_kernel::kernel: Agent TOML on disk differs from DB, updating agent=coder
```
Changes made at runtime (`openfang agent set <uuid> model x`, dashboard edits) are silently gone
after a restart.

**Root cause:** boot reconciles DB ← disk, unconditionally, for every agent. `agent.toml` on disk is
the **only** durable source of truth for agent configuration. The DB copy is a cache that is
overwritten, never merged.

**Fix:** **edit `agent.toml` on disk, not via `agent set`.** Treat `agent set` as a temporary,
session-scoped override.
```bash
openfang stop
$EDITOR /home/kyzdes/.openfang/agents/<name>/agent.toml
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start
```

**Evidence:**
```
$ grep -c "differs from DB" daemon-start.log
30
```
All 30 agents, every boot. This fires even when nothing was edited — so it is reconciliation, not
change detection.

**Marker:** VERIFIED

---

### G12: `openfang status` is **not read-only** — it boots a kernel and writes the DB

**Symptom:** you run "just a status check" against a stopped daemon and it takes ~13 seconds,
prints a full boot sequence, and modifies the database.

**Root cause:** when the daemon is not running, the CLI **boots a full in-process kernel** to answer
the question: it loads config, applies provider URL overrides, builds the 334-model catalog, loads
61 skills and 9 hands, and then runs the disk→DB agent reconciliation from G11 — **writing to
`openfang.db`**. The output header even admits it: `>> OpenFang Status (in-process)`.

**This means `status`, `models aliases`, `skill list`, `agent list`, `agent new`, `agent spawn`, and
`agent kill` are all writers, not readers, when the daemon is down.** Any "read-only investigation"
of a stopped install mutates it — and the audit trail is a **hash-chained Merkle log**, so the
pollution is *irreversible*. You cannot delete your own footprints.

**Each in-process boot writes ~9 `audit_entries` rows.** VERIFIED, exactly:
```
audit_entries before:  977
$ openfang status
audit_entries after:   986        # Δ = +9, from ONE status call
```
This compounds silently. `daemon-lifecycle.md` recorded **887** when it was written; the live count
reached **977** with the daemon down the whole time — **Δ = 90 = exactly 10 × 9**, i.e. **ten
in-process kernel boots** happened just from agents running "read-only" checks out of this playbook.
Do not be the eleventh.

**Fix — never use `status` to ask "is it up?".** Use the HTTP probe. It is a socket connect: zero
DB writes, ~3ms instead of ~13s, and `000` unambiguously means down.
```bash
curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:4200/api/health
# 000 = daemon down (connection refused) · 200 = up
```
Then:
- If you must not touch state, query `openfang.db` directly with `sqlite3` + `LIMIT` (a true read).
  Open it read-only so you cannot fumble a write: `sqlite3 "file:$DB?mode=ro" "SELECT … LIMIT 20"`.
  **The DB is at `~/.openfang/data/openfang.db`, not `~/.openfang/openfang.db`** — VERIFIED; the
  wrong path fails with `unable to open database file`, which reads like a permissions problem and
  is not.
- Prefer the HTTP API when the daemon **is** up — those are genuine reads.
- If you truly need `status`, budget ~13s, accept the +9 rows, and run it **once**.

**Evidence:**
```
$ openfang status 2>/dev/null | head -8
  >> OpenFang Status (in-process)
  Agents:      30
  Provider:    gonka-1
  Model:       moonshotai/kimi-k2.6
  Data dir:    /home/kyzdes/.openfang/data
  Daemon:      NOT RUNNING

$ openfang status 2>&1 | grep "differs from DB" | head -3
INFO openfang_kernel::kernel: Agent TOML on disk differs from DB, updating agent=data-scientist
INFO openfang_kernel::kernel: Agent TOML on disk differs from DB, updating agent=legal-assistant
...
```
A `status` invocation produced **30 agent-row rewrites** (one per agent, re-stamping `updated_at`)
**plus the +9 `audit_entries` rows** measured above — two distinct write paths, both irreversible.
The re-stamp is visible afterwards: `agents.updated_at` is identical on all 30 rows.

**`health` and `doctor --json` are the exceptions — they are genuinely side-effect free.** VERIFIED
by a fresh agent:
```
audit before: 977
$ openfang doctor --json >/dev/null 2>&1 ; openfang health >/dev/null 2>&1
audit after:  977      delta: 0     (DB mtime unchanged)
```
**SUSPECT:** this contradicts the earlier blanket claim that `doctor` is a writer. Both may hold —
`--json` likely takes a lighter path than bare `doctor`. **What settles it:** snapshot
`SELECT COUNT(*) FROM audit_entries`, run **bare** `openfang doctor`, re-count. Until someone does,
treat bare `doctor` as a writer and use `doctor --json`. For liveness alone, prefer the `curl`
probe above over both — it is cheaper than either and cannot be wrong.

**Correction to the seed:** the seed claims `status`/`system info` print `Data dir: ?`. **They do
not on 0.6.9 here** — it prints `Data dir: /home/kyzdes/.openfang/data` correctly. That gotcha is
fixed or was misread; do not carry it forward.

**Marker:** VERIFIED (+9 delta reproduced here: 977 → 986 from one `status`)

---

### G13: `minimax-m2.7` 500s on parallel tool calls, and there is no `parallel_tool_calls` knob

**Symptom:** the agent goes silent (e.g. Telegram never replies). In the audit trail:
```
error: LLM driver error: Provider overloaded: {"error":{"message":"Failed to generate completions:
Failed to apply prompt template: invalid operation: This model only supports single tool-calls at
once! (in default:95)","type":"Internal Server..."}}
```

**Root cause:** `minimaxai/minimax-m2.7` on gonka rejects parallel tool calls at the prompt-template
layer and returns **500**. OpenFang's driver classifies the 500 as "Provider overloaded" — a
**misleading error**: it is a permanent model incompatibility, not transient load, so retrying
never helps. **OpenFang has no `parallel_tool_calls` setting anywhere** — you cannot make the model
compatible; you must change the model.

**Fix:** use a model that handles parallel tool calls. `moonshotai/kimi-k2.6` does.
```bash
# in config.toml, [default_model] and every [[fallback_providers]]:
model = "moonshotai/kimi-k2.6"
```

**Evidence:**
```
$ sqlite3 openfang.db "SELECT action, outcome, COUNT(*) FROM audit_entries GROUP BY action, outcome ORDER BY 3 DESC LIMIT 8;"
AgentMessage|error: LLM driver error: Provider overloaded: {"error":{"message":"Failed to generate
completions: Failed to apply prompt template: invalid operation: This model only supports single
tool-calls at once! (in default:95)","type":"Internal Server...|15
```
15 occurrences before the model was switched.

**Marker:** VERIFIED

---

### G14: 22 of 30 bundled agents hardcode `GROQ_API_KEY` / `GEMINI_API_KEY` in `[[fallback_models]]`

**Symptom:** 138 audit rows of:
```
error: Boot failed: Agent LLM driver init failed: Missing API key: Set GROQ_API_KEY environment
variable for provider 'groq'
```

**Root cause:** the shipped agent templates hardcode fallback providers that do not exist on your
install. Neither key exists in `secrets.env` (which has only `GONKA_1..4_API_KEY`,
`TELEGRAM_BOT_TOKEN`, `NIM_1_API_KEY`).

⚠️ **Correction — this entry used to say "11 + 19 = 30, every single agent is affected". That is
coincidence arithmetic and it is WRONG.** `grep -rl` counts **files**, and the two sets **overlap**.
Re-measured (`LC_ALL=C`, `--include=agent.toml`):

| set | count | which |
|---|---|---|
| `GROQ_API_KEY` | 11 | |
| `GEMINI_API_KEY` | 19 | |
| **both** | **8** | analyst · coder · code-reviewer · data-scientist · debugger · legal-assistant · researcher · test-engineer |
| **union = affected** | **22** | |
| **neither = clean** | **8** | health-tracker · hello-world · home-automation · **ops** · personal-finance · translator · travel-planner · tutor |

`11 + 19 = 30` is luck, not a proof. **The 8 clean agents include `ops` and `health-tracker`** — i.e.
the scheduled, cost-relevant ones G4 warns about are exactly the ones NOT affected here.

**Fix:** strip the bogus `[[fallback_models]]` blocks from the **22** affected `agent.toml` files
(daemon stopped — G11), letting each inherit the global chain. Do not go editing 30 files; 8 have
nothing to strip.
```bash
grep -rl "GROQ_API_KEY\|GEMINI_API_KEY" /home/kyzdes/.openfang/agents --include="agent.toml"  # → 22
# then, with the daemon stopped, delete the [[fallback_models]] blocks that name them
```

**Evidence:**
```
$ grep -rl "GROQ_API_KEY"   ~/.openfang/agents --include="agent.toml" | wc -l   → 11
$ grep -rl "GEMINI_API_KEY" ~/.openfang/agents --include="agent.toml" | wc -l   → 19
$ grep -rl "GROQ_API_KEY\|GEMINI_API_KEY" ~/.openfang/agents --include="agent.toml" | wc -l → 22
$ ls ~/.openfang/agents | wc -l                                                 → 30
$ sqlite3 openfang.db "SELECT COUNT(*) FROM audit_entries WHERE outcome LIKE '%GROQ_API_KEY%';" → 138
```

**Marker:** VERIFIED (union/overlap re-measured 2026-07-14; the old `11+19=30` claim is WITHDRAWN)

---

### G15: The last-resort NIM fallback does not work — and in the last session it was *refusing*, not unreachable

**Symptom — the dominant one in the most recent session (15 of 17 NIM failures):**
```
API error (400): {"status":400,"title":"Bad Request","detail":"Function id
'84eb5de1-166b-4bb4-a01b-4f51bd90aa52': DEGRADED function cannot be invoked"}
```
**Symptom — the historical one (237 audit rows, and only 2 hits in the last session):**
```
error: LLM driver error: Request failed: HTTP error: error sending request for url
(https://integrate.api.nvidia.com/v1/chat/completions)
```

**Root cause — two distinct faults, do not merge them.** `nim-1` is the final link in the chain, so
when all four gonka providers fail there is **no working fallback**. *Why* nim-1 fails has changed:
the "237 audit rows" figure is a **historical transport/DNS failure**; the last session's chain was
failing **`DEGRADED function cannot be invoked`** — a per-function 400 from a host that answered
fine. **NIM was reachable and refusing.** Retries do not help either way.

⚠️ **The reachability probe is misleading — it returns `200` on a box where NIM is 100% useless.**
`DEGRADED` is per-function, not host-level, so a green probe proves only that DNS and TLS work. Do
not read `200` as "trustworthy".
```bash
curl -sS --max-time 8 -o /dev/null -w "nim %{http_code}\n" \
  -H "Authorization: Bearer $NIM_1_API_KEY" https://integrate.api.nvidia.com/v1/models
```

**Fix:** replace the last fallback with something that works, or accept that gonka-1..4 is the real
chain. ⚠️ **That third option is vacuous exactly when you need it** — "gonka-1..4 is the real chain"
is no comfort when gonka is the thing that is down, which is the common case. For the
all-providers-dead decision tree, and for the **gonka** probe (the primary, 4/5 of the chain — G15
only ever covered NIM, the least important link), go to **`models-providers.md` → "Every configured
provider is dead at once"**.

**Evidence:**
```
AgentMessage|error: LLM driver error: Request failed: HTTP error: error sending request for url
(https://integrate.api.nvidia.com/v1/chat/completions)...|237
AgentMessage|error: LLM driver error: Request failed: {"status":400,...,"detail":"Function id
'84eb5de1-...': DEGRADED function cannot be invoked"}...|15
```

**Chain length — do NOT infer it from the highest `driver_index` you see.** An earlier revision of
this gotcha claimed "6 drivers = 1 default + **5** `[[fallback_providers]]`", deduced from seeing
`driver_index=5` in the log. **That deduction is wrong.** Live: `grep -c
'^\[\[fallback_providers\]\]' ~/.openfang/config.toml` → **`4`**. The 6th driver appears only for
agents that ship their own `[[fallback_models]]` block, which is *not* `[[fallback_providers]]` and
is *not* global. **The chain length varies per agent (5 or 6).**
**`models-providers.md` "The fallback driver chain" is the sole owner of this math — go there.**
Also seen at the end of the chain:
```
WARN openfang_runtime::drivers::fallback: Fallback driver failed, trying next driver_index=5
model=meta/llama-3.3-70b-instruct error=API error (503): {"error":{"message":"ResourceExhausted:
Worker local total request limit reached (24/16)","type":"Service Unavailable","code":503}}
```

**Marker:** VERIFIED

---

### G16: OpenAI-compatible custom `base_url` strips the namespace from slashed model ids

**Symptom:** `model_not_found` for a model that plainly exists at the provider.

**Root cause:** upstream #1195 — for `provider = "openai"` with a custom `base_url`, the driver
splits the model id on `/` and sends only the last segment: `openai/gpt-oss-120b` →
`gpt-oss-120b` → `model_not_found`.

**Relevance here:** this install's `default_model` is **`moonshotai/kimi-k2.6` on a custom
`base_url`** (`https://api.gonkagate.com/v1`) — the exact shape that triggers #1195. It works
because the provider is named `gonka-1`, **not** `openai`; #1195 is scoped to `provider="openai"`.

**Fix:** **never name a custom OpenAI-compatible provider `openai`.** Give it any other name
(`gonka-1`, `nim-1`, …) and set `base_url` + `provider_urls`. If you must use `provider="openai"`,
use an unslashed model id.

**Evidence:** live config, working:
```toml
[default_model]
provider = "gonka-1"                            # NOT "openai" — this is what saves us
model = "moonshotai/kimi-k2.6"                  # slashed id, on a custom base_url
base_url = "https://api.gonkagate.com/v1"
```
`Model catalog: 334 models, 143 available` and 64 `AgentMessage|ok` rows → the slashed id resolves.

**Marker:** UPSTREAM (#1195) · local non-reproduction VERIFIED

---

### G17: Embeddings — only ollama works, and backfill never happens

**Symptom:** memory recall returns nothing useful; most rows in `memories` have `embedding IS NULL`.

**Root cause:** two upstream bugs make every non-ollama path wrong:
- **#1212** — the `openai` embedding driver **hardcodes 6 cloud providers and ignores `base_url`**.
  Chat routes to your local/custom endpoint while **embedding-recall silently goes to OpenAI cloud**
  (a data-egress problem, not just a bug).
- **#1251** — the embedding `base_url` **force-appends `/v1`**: `http://h:8004/v3` → `http://h:8004/v3/v1`.

And separately: **embeddings are only computed for memories created *after* the driver is
configured. There is no backfill.** Every memory written before you set `[memory] embedding_*` stays
`NULL` forever.

**Fix:** use the ollama provider — it is the one path that works.
```toml
[memory]
embedding_provider = "ollama"
embedding_model = "mxbai-embed-large"
```
```bash
curl -s --max-time 5 http://127.0.0.1:11434/api/tags | head -c 200   # ollama must be up FIRST
```

**Evidence:**
```
$ sqlite3 openfang.db "SELECT COUNT(*) total, SUM(embedding IS NOT NULL) with_emb FROM memories;"
64|6
$ curl -s --max-time 5 http://127.0.0.1:11434/api/tags | head -c 120
{"models":[{"name":"mxbai-embed-large:latest",...
```
**Resolves the seed's SUSPECT #7.** The seed found 2/60 and asked whether the driver was working at
all. It is: the count has moved **2/60 → 6/64**, i.e. **all 4 memories created since the driver was
configured got embeddings, and none of the 58 older ones did.** The driver is fine; the absence of
backfill is the real defect. Older memories are unrecallable by similarity unless you delete and
recreate them.

**Marker:** VERIFIED (resolves seed SUSPECT) · #1212/#1251 UPSTREAM

---

### G18: `memories.source` and `agents.state` are double-encoded JSON in the DB

**Symptom:** a correct-looking query silently returns zero rows:
```sql
SELECT * FROM memories WHERE source='conversation';   -- 0 rows, always
```

**Root cause:** the values are stored **with their JSON quotes included** — the column contains the
6-byte string `"conversation"`, not `conversation`. Serde serialized the enum to JSON and the result
was written to a TEXT column without unwrapping.

**Fix:** match the quotes, or strip them.
```sql
SELECT * FROM memories WHERE source='"conversation"';         -- works
SELECT * FROM memories WHERE TRIM(source,'"')='conversation'; -- portable
```

**Evidence:**
```
$ sqlite3 openfang.db "SELECT DISTINCT source FROM memories LIMIT 10;"
"conversation"
$ sqlite3 openfang.db "SELECT state, COUNT(*) FROM agents GROUP BY state LIMIT 10;"
"suspended"|30
```
The quotes are literal, in both tables.

**Marker:** VERIFIED

---

### G19: `agents.state` in the DB is permanently `"suspended"` and never written back

**Symptom:** the DB says every agent is suspended; the CLI and API say every agent is Running.

**Root cause:** runtime state lives in the kernel's memory and is **never persisted back** to
`agents.state`. The column holds whatever was last written at spawn time. It is a **stale field, not
a status** — do not build monitoring on it.

**Fix:** get state from the API — daemon **up** only. **No auth header is needed on this install:**
there is no `[server]`/`[api]` section in `config.toml` at all and **no API key is configured**
(VERIFIED). This entry used to show `-H "Authorization: Bearer $KEY"`; `$KEY` expands to empty, the
header is noise, and it sends readers hunting for a credential that does not exist.
```bash
curl -s http://127.0.0.1:4200/api/agents | head -c 2000     # no trailing slash — /api/agents/ 404s
```
With the daemon **down** there is no live state to read — nothing is running, so there is nothing to
be stuck. Do **not** reach for `openfang status` to "check": it boots an in-process kernel and writes
+9 irreversible audit rows (G12).

**Evidence:**
```
$ sqlite3 openfang.db "SELECT state, COUNT(*) FROM agents GROUP BY state LIMIT 10;"
"suspended"|30

$ openfang status 2>/dev/null | head -14
  >> Persisted Agents
    doc-writer (5bcdda4f-e590-43b5-b416-44b019e0e798) -- Running
    tutor (054d89cb-4cc7-4771-8f3e-87735dd7d2b1) -- Running
    ...
```
Both statements are "true" simultaneously — the CLI reports the in-process kernel's view, the DB
reports a fossil.

**Marker:** VERIFIED

---

### G20: `doctor` is blind to custom providers and to `secrets.env`

**Symptom:** `doctor` reports no keys and a missing `.env` while the daemon authenticates fine:
```
  - .env file not found (create with: openfang config set-key <provider>)
  ○ Groq           (GROQ_API_KEY not set)
  ○ OpenRouter     (OPENROUTER_API_KEY not set)
  ○ Anthropic      (ANTHROPIC_API_KEY not set)
  ...
```

**Root cause:** `doctor` checks a **hardcoded list of well-known cloud providers** against a `.env`
file. This install uses **`secrets.env`** and custom providers (`gonka-1..4`, `nim-1`) that appear
nowhere on doctor's list. Two secret paths with no cross-awareness. **`doctor`'s provider verdict is
meaningless for custom providers — ignore it.**

**Fix:** verify keys the real way — check `secrets.env` and the audit trail for auth failures.
```bash
grep -oE "^[A-Z0-9_]+=" /home/kyzdes/.openfang/secrets.env      # names only, never values
sqlite3 openfang.db "SELECT COUNT(*) FROM audit_entries WHERE outcome LIKE '%Missing API key%';"
```
`doctor` **is** trustworthy for: `openfang_dir`, `config_file`, `database`, `disk_space`,
`agent_manifests`, `port`.

**Evidence:**
```
$ openfang doctor --json | head -20
{ "all_ok": false, "checks": [
  {"check":"openfang_dir","path":"/home/kyzdes/.openfang","status":"ok"},
  {"check":"env_file","status":"warn"},          ← false alarm; secrets.env exists, 0600
  {"check":"config_file","status":"ok"},
  {"check":"daemon","status":"warn"},            ← true, daemon is down
  {"check":"port","address":"127.0.0.1:4200","status":"ok"},
  {"check":"database","status":"ok"}, ...
  {"check":"rust","status":"fail"},              ← cosmetic: toolchain check, not needed at runtime
  {"check":"node","status":"warn"} ]}            ← cosmetic

$ grep -oE "^[A-Z0-9_]+=" /home/kyzdes/.openfang/secrets.env
GONKA_1_API_KEY= GONKA_2_API_KEY= GONKA_3_API_KEY= GONKA_4_API_KEY= TELEGRAM_BOT_TOKEN= NIM_1_API_KEY=
```
`rust: fail` / `node: warn` are **cosmetic** — they check for dev toolchains, not runtime deps.
`all_ok: false` on a healthy install is normal. **Never run `doctor --repair` to "fix" these.**

**Marker:** VERIFIED

---

### G21: `skill list` only enumerates USER skills — the 61 bundled ones are invisible

**Symptom:**
```
$ openfang skill list
No skills installed.
```
…while boot says `Loaded 61 bundled skill(s)`.

**Root cause:** the 61 skills are **compiled into the binary**; `skill list` walks the user skills
directory only. There is no `~/.openfang/skills/`. `/api/skills` returns empty for the same reason.

**Fix:** don't trust `skill list` for existence. Bundled skills are real and usable regardless.
Per-agent user skills live in `workspaces/<agent>/skills/`. Use the in-agent `skill_list` /
`skill_describe` tools to see what an agent actually has.

**Evidence:**
```
$ openfang skill list 2>/dev/null
No skills installed.
$ openfang doctor 2>&1 | grep "bundled skill"
INFO openfang_skills::registry: Loaded 61 bundled skill(s)
```
Both from the same binary, seconds apart.

**Marker:** VERIFIED

---

### G22: Trailing-slash routes 404 — but the slash forms are the literals in the binary

**Symptom:** `GET /api/agents/` → 404; `GET /api/agents` → 200.

**Root cause:** the router registers non-slash paths, but the **string literals embedded in the
binary carry the trailing slash**. Anyone scripting endpoints by `strings`-mining the binary will
produce 404s.

**Fix:** strip trailing slashes from any route you extract from the binary. Confirm against a live
daemon before scripting.

**Evidence:**
```
$ strings /home/kyzdes/.openfang/bin/openfang | grep -E "^/api/agents/?$|^/api/agents/" | head -4
/api/agents/
/api/agents/{id}/session/compact...
/api/agents/{id}/ws
```
The literal is `/api/agents/` — with the slash. **Could not re-test the 404 live** (daemon down,
`curl http://127.0.0.1:4200/api/status` → exit 7 / HTTP `000`); the 404 behavior is carried from the
seed's verification while the daemon was up.

**Marker:** VERIFIED (binary literals) · 404 behavior UNVERIFIED this session (daemon down)

---

### G23: `daemon-start.log` is full of ANSI escapes — naive greps silently miss

**Symptom:** a grep that must match returns **zero** results:
```bash
$ grep -oE "timeout_secs[=: ]+[0-9]+" daemon-start.log
# (nothing)
```
…even though the log obviously contains `timeout_secs=60`.

**Root cause:** the daemon writes **colorized** tracing output to stdout, and `start`'s stdout is
your log file. Every field name is wrapped in escapes — the real bytes are
`\x1b[3mtimeout_secs\x1b[0m\x1b[2m=\x1b[0m60`. So `timeout_secs=` never appears literally, and your
regex matches nothing. **This fails silently — you conclude "not in the log" and you are wrong.**

**Fix:** strip ANSI first, always.
```bash
sed -r 's/\x1b\[[0-9;]*m//g' /home/kyzdes/.openfang/daemon-start.log | grep -oE "timeout_secs=[0-9]+" | sort | uniq -c
```
Bare-word greps (`grep -c "Auto-recovering"`) work because message text is unescaped; only
**structured fields** and level names are wrapped. If you are grepping a `key=value` field, strip.

**Evidence:** the exact pair of commands above — the unstripped form returned nothing; the stripped
form returned `1953 timeout_secs=180 / 81 timeout_secs=60`. This gotcha almost caused this document
to report "the seed's timeout claim does not reproduce."

**Marker:** VERIFIED (new — not in the seed; caught mid-investigation)

---

### G24: Stale `daemon.json` does NOT block start — this gotcha was WRONG

**Retracted.** This entry used to claim that a stale `daemon.json` blocks `openfang start` because it
"is not validated against a live process", and prescribed `openfang doctor --repair` as the fix.
**Both halves were wrong, and the fix was dangerous.**

**What actually happens:** the guard *does* validate against a live process, and **self-heals**:
```rust
if is_process_alive(info.pid) && is_daemon_responding(&info.listen_addr) { return Err(...) }
info!("Removing stale daemon info file");   // else: deletes it and starts normally
```
So a stale file is removed for you. `start` only refuses when a daemon really is alive and answering
— in which case it is not stale and you should not delete it.

🚨 **Never run `openfang doctor --repair` for this, or for anything.** It is interactive, and it
regenerates `config.toml` from `detect_best_provider()` — silently replacing this install's
gonka/kimi setup if the file is ever absent or renamed. `config.toml.bak*` files already exist here,
which is how that goes wrong quietly.

**If you are certain no daemon is alive** and want the file gone anyway:
```bash
curl -s -o /dev/null -m 3 -w '%{http_code}\n' http://127.0.0.1:4200/api/health   # must be 000
pgrep -f 'openfang start' || rm /home/kyzdes/.openfang/daemon.json
```

**Note the related real trap (different direction):** if `daemon.json` is *missing while the daemon
is alive*, every CLI command believes there is no daemon — `openfang stop` prints `No running daemon
found` and exits 0, and you cannot stop it through the CLI. That one is real. →
`daemon-lifecycle.md`, which is the **sole owner** of `daemon.json` semantics.

**Evidence:** `ls -la /home/kyzdes/.openfang/daemon.json` → no such file. This install was
**OOM-scope-killed and still shut down cleanly with no stale file** — directly contradicting the old
claim that an OOM kill is "the most likely way you get here".

**Marker:** the retraction is VERIFIED against the upstream guard quoted in `daemon-lifecycle.md`.
The old seed claim is **WITHDRAWN**.

---

### G25: A config parse failure degrades to defaults **silently**

**Symptom:** a subtle wholesale behavior change — wrong model, wrong port, no Telegram — with one
easily-missed line:
```
WARN Failed to parse config, using defaults
```

**Root cause:** a TOML syntax error or a bad type does **not** abort startup. The kernel logs a
warning and boots with **built-in defaults**, discarding your entire config. If you did not read the
log, you now have a daemon running someone else's configuration.

**Fix:** validate every config change against the boot log before assuming it took.
```bash
sed -r 's/\x1b\[[0-9;]*m//g' daemon-start.log | grep -iE "Loaded configuration|using defaults|Fallback provider configured"
```
A healthy boot echoes your config back:
```
INFO openfang_kernel::config: Loaded configuration path=/home/kyzdes/.openfang/config.toml
INFO openfang_kernel::kernel: Fallback provider configured provider=gonka-2 model=moonshotai/kimi-k2.6
INFO openfang_kernel::kernel: Fallback provider configured provider=gonka-3 model=moonshotai/kimi-k2.6
INFO openfang_kernel::kernel: Fallback provider configured provider=gonka-4 model=moonshotai/kimi-k2.6
INFO openfang_kernel::kernel: Fallback provider configured provider=nim-1 model=meta/llama-3.3-70b-instruct
INFO openfang_kernel::kernel: applied 5 provider URL override(s)
```
**Count the echoes.** 4 fallbacks + 5 URL overrides matches the file. A missing echo = a key that
did not parse. Related: an **unknown key is ignored without any warning at all** (this is how
`[[fallback_models]]` in `config.toml` silently does nothing — see G10).

**Evidence:** `grep -m2 "using defaults" daemon-start.log` → no match (config parses cleanly here);
the healthy-boot echoes above are real output from `openfang status 2>&1`.

**Marker:** VERIFIED (healthy path) · degradation path UNVERIFIED (would require corrupting the
production config — forbidden)

---

### G26: A deleted workflow reappears after restart

**Symptom:** `workflow delete <id>` succeeds; after a daemon restart the workflow is back.

**Root cause:** upstream #1192 — deletion removes the runtime entry but not the on-disk definition,
which is re-imported at boot (same disk-wins pattern as G11).

**Fix:** delete the workflow's file on disk too, with the daemon stopped.

**Evidence:** no workflows on this install to test against (`cron_jobs.json` is `[]`; the seed
recorded `/api/workflows` as empty).

**Marker:** UPSTREAM (#1192) · UNVERIFIED locally (no workflows exist here)

---

### G27: WAL is not checkpointed while running — copying `.db` alone gives a stale snapshot

**Symptom:** you back up `openfang.db`, restore it, and recent agents/sessions/memories are missing.

**Root cause:** SQLite in WAL mode. While the daemon runs, recent commits live in
`openfang.db-wal`, which grew to 733 KB against a 790 KB DB — i.e. **~half the database was outside
the file you copied**. No periodic checkpoint runs.

**Fix:** either stop the daemon first (shutdown checkpoints and removes the WAL), or copy all three
files, or use the SQLite backup API.
```bash
# Best — consistent, safe against a LIVE daemon:
sqlite3 /home/kyzdes/.openfang/data/openfang.db ".backup '/tmp/openfang-backup.db'"

# Acceptable — daemon stopped:
cp /home/kyzdes/.openfang/data/openfang.db* /path/to/backup/
```

**Evidence:** with the daemon **stopped**, the WAL is gone and the DB is whole:
```
$ ls -la /home/kyzdes/.openfang/data/
-rw-r--r-- 1 kyzdes kyzdes 933888 Jul 14 12:28 openfang.db      # no -wal, no -shm
```
This **confirms** the mechanism: a clean shutdown checkpointed the WAL into the main file (790 KB +
733 KB WAL → 934 KB DB, no WAL). The hazard is real but applies **only while the daemon is
running**. Right now (daemon down) a plain `cp` is safe.

**Marker:** VERIFIED

---

## Tier 4 — traps, security, cosmetics

### G28: `openfang.db` is 0644 (world-readable) with full transcripts

**Symptom:** none — that is the problem.

**Root cause:** the DB is created 0644 while `config.toml` and `secrets.env` are correctly 0600.
It contains **full conversation transcripts** (`sessions.messages`, `canonical_sessions.messages`),
all memories, and the audit trail. On a multi-user box every local user can read every conversation.
`daemon-start.log` is 0664 and leaks operational detail too.

**Fix:**
```bash
chmod 600 /home/kyzdes/.openfang/data/openfang.db
chmod 700 /home/kyzdes/.openfang/data
chmod 600 /home/kyzdes/.openfang/daemon-start.log
```
**Re-check after any reinstall or DB re-create** — the daemon sets the permissive mode itself, so
this reverts.

**Evidence:**
```
$ stat -c "%a %n" openfang.db config.toml secrets.env daemon-start.log
644 /home/kyzdes/.openfang/data/openfang.db
600 /home/kyzdes/.openfang/config.toml
600 /home/kyzdes/.openfang/secrets.env
664 /home/kyzdes/.openfang/daemon-start.log
```

**Marker:** VERIFIED

---

### G28a: An omitted `[capabilities].tools` array is FAIL-OPEN — it grants ALL 65 tools

**Symptom:** a hand-written or migrated `agent.toml` leaves `tools` out of `[capabilities]`
(intending "no tools" or just forgetting). The agent silently receives **every** tool —
`shell_exec`, `docker_exec`, `process_start`, `agent_spawn`, `agent_kill`, `file_write`,
`browser_run_js`, all 65.

**Root cause:** an absent `tools` array does **not** mean deny-all. It means unrestricted. The
per-capability flags do not compensate: `agent_spawn = false` was present in the manifest and
`agent_spawn` was **still granted**.

**Evidence (VERIFIED, 2026-07-14):** deleted the `tools` line from `hello-world` and read the boot's
`Tools selected for LLM request` line.
```
tools present (6 ids):  tool_count=6
tools line deleted:     tool_count=65   ← shell_exec, docker_exec, process_start, agent_kill, …
```

**Fix:** treat `tools` as a **required** explicit allowlist on every agent. Audit for the omission:
```bash
for f in ~/.openfang/agents/*/agent.toml; do
  grep -q '^\[capabilities\]' "$f" && ! grep -qE '^\s*tools\s*=' "$f" && echo "WIDE OPEN: $f"
done
```
On this install all 30 declare it, so nothing is currently exposed. But combined with
`network = ["*"]` and a channel anyone can message, an omitted `tools` is a remote shell. **Marker: VERIFIED.**

### G29: `--yolo` auto-approves `shell_exec` for all 30 agents, with `network=["*"]`

**Symptom:** you pass `--yolo` to silence approval prompts and hand 30 LLM-driven agents unattended
shell access to the machine.

**Root cause:** `--yolo` sets auto-approve **globally**, not per-agent or per-tool. It covers
`shell_exec` and `docker_exec`. The bundled agents ship `network = ["*"]`. Combined with the
schedules in G4, **an autonomous agent can run arbitrary shell commands on a 5-minute timer with no
human in the loop.** Worse, the approval-denial text injected back into the model literally hints
`set auto_approve = true…` — **the model is being coached to ask you to disable the safety.** Treat
that suggestion, from any agent, as a red flag.

**Fix:** never use `--yolo` on a machine you care about. Scope capability in `agent.toml` instead:
```toml
[capabilities]
network = ["api.gonkagate.com"]     # not ["*"]
shell = ["git status", "ls *"]      # glob allowlist, not blanket
```
Approve interactively: `openfang approvals list` → `openfang approvals approve <id>`.

**Evidence:** seed-verified from the CLI surface (`start [--yolo]`). Not exercised here —
**running `--yolo` against this production install is forbidden**, and given G1/G2 the blast radius
is the machine.

**Marker:** UPSTREAM/seed VERIFIED · deliberately UNVERIFIED here (too dangerous to test)

---

### G30: `vault` is uninitialized, but `openfang add --key` claims to store in it

**Symptom:** `Vault not initialized. Run: openfang vault init` — or worse, a command that claims to
have stored a secret in a vault that does not exist.

**Root cause:** the vault is an independent, opt-in subsystem (`openfang-extensions/src/vault.rs`,
AES-GCM `openfang-vault-v1`, master key in the OS keyring). It is **not** where this install's
secrets live — those are in `secrets.env`. Third secret path, still no cross-awareness (cf. G20).

**Fix:** know which store you are in. This install uses `secrets.env`; leave the vault alone unless
you intend to migrate. The env var is **`OPENFANG_VAULT_KEY`**, not `VAULT_KEY`.

**Evidence:** binary literals (bounded `strings … | head -c`):
```
Vault not initialized. Run: openfang vault init
Vault already exists. Delete it first to re-initialize.
OPENFANG_VAULT_KEY
Using existing vault key from OS keyring
Vault master key stored in OS keyring
openfang-vault-v1
```
**Correction to the seed:** the seed's env list says `VAULT_KEY`. The real name is
**`OPENFANG_VAULT_KEY`**. Note this install's OS keyring is the user's **keys-keeper vault** — do
not let `vault init` write into it casually.

**Marker:** VERIFIED (binary literals)

---

### G31: `agent chat`/`agent kill`/`cron create` need a UUID; `chat`/`message`/`memory`/`sessions` take a name

**Symptom:** `openfang agent chat assistant` fails; `openfang chat assistant` works. Inconsistent and
undocumented.

**Root cause:** two command families with two different identifier conventions.

🔴 **Correction — `cron create` was listed on the NAME side. That was WRONG, and it carried a
`VERIFIED` marker it had not earned** (the old evidence block proved only the `agent chat` split and
never touched `cron create`; the claim was back-derived from the CLI's `--help` string, which lies).
**`cron create` takes a UUID.** The arg help says `Agent name or ID to run`; the CLI forwards the
string verbatim and the kernel calls `uuid::Uuid::parse_str(agent_id)`, so a name yields:
`Failed: Invalid agent ID: invalid length: expected length 32 for simple format, found 3`.
`automation.md` #3 had this right all along and is the **sole owner** of the cron API contract.

**Fix:** memorize the split.
```
UUID:  agent chat <UUID> · agent kill <UUID> · agent set <UUID> <FIELD> <VALUE> · cron create <UUID>
NAME:  chat <NAME> · message <NAME> · memory list <NAME> · sessions <NAME>
```
**Get the UUID offline — free, and it works with the daemon down:**
```bash
sqlite3 -readonly ~/.openfang/data/openfang.db "SELECT id,name FROM agents LIMIT 40;"
```
⚠️ **Do NOT use `openfang status` for this.** With the daemon down it boots an in-process kernel and
writes **+9 irreversible audit rows** (G12) — this entry used to prescribe exactly that. Once
`health` is `200`, `curl -s http://127.0.0.1:4200/api/agents` is also free.

**Evidence:**
```
$ openfang cron create --help
Arguments:  <AGENT>   Agent name or ID to run          ← the help LIES
$ strings -n 8 ~/.openfang/bin/openfang | grep -F "expected length 32"
invalid length: expected length 32 for simple format, found     ← verbatim, ×1

    doc-writer (5bcdda4f-e590-43b5-b416-44b019e0e798) -- Running
    orchestrator (91c689c2-17e3-4763-b360-65aea020cc57) -- Running
```
Sentinel system agent: `00000000-0000-0000-0000-000000000001`.

**Marker:** the `agent chat`/`agent kill` UUID split is VERIFIED. The `cron create` correction is
VERIFIED against the binary (`--help` text + the `parse_str` error string, re-confirmed 2026-07-14).
The old NAME-side listing is **WITHDRAWN**.

---

### G32: `max_concurrent_tools` may be parsed-but-inert

**Symptom:** you set `max_concurrent_tools` and still get provider-side concurrency errors:
```
API error (503): {"error":{"message":"ResourceExhausted: Worker local total request limit reached
(24/16)","type":"Service Unavailable","code":503}}
```

**Root cause (SUSPECT):** the key appears in docs, `agent.toml`, and the TUI, but an upstream code
search found **no reads in `openfang-runtime` or `openfang-kernel`** — suggesting it is deserialized
and never enforced. The 503 above is the provider's own limiter (`24/16`), fired anyway.

**What would settle it:** with the daemon up, set `max_concurrent_tools = 1` on one agent, give it a
task requiring several tool calls, and count concurrent tool spans in the log. If they overlap, the
key is inert. **Cannot run here — the daemon is down and starting it is out of scope.**

**Fix meanwhile:** do not rely on it. Control concurrency by reducing agents and schedules (G4), and
treat the fallback chain (G15) as your real overflow valve.

**Evidence:**
```
$ grep -rh "max_concurrent_tools" /home/kyzdes/.openfang/agents --include="*.toml" | sort | uniq -c
      3 max_concurrent_tools = 10
     12 max_concurrent_tools = 5
```
**Correction to the seed:** the seed reports `max_concurrent_tools=10` as the value in `agent.toml`.
The real distribution is **3 agents at 10, 12 agents at 5 — and 15 of 30 agents do not set it at
all.** Also the observed provider limit was `24/16`, not the seed's `40/16` (it varies with load).

**Marker:** SUSPECT (unchanged from seed; resolution procedure above)

---

### G33: `models aliases` — seed says broken, reproduces fine

**Symptom (claimed):** the table view renders JSON envelope keys as rows.

**Root cause (hypothesis):** the CLI renders the daemon's HTTP envelope when the daemon is **up**,
but formats the in-process catalog correctly when it is **down**. That would explain both
observations.

**What would settle it:** re-run `openfang models aliases` with the daemon running. If it garbles,
the bug is in the API-envelope rendering path only.

**Evidence:** with the daemon **down**, output is correct:
```
$ openfang models aliases 2>/dev/null | head -6
ALIAS                          RESOLVES TO
------------------------------------------------------------
chutes-deepseek-v3             chutes/deepseek-ai/DeepSeek-V3
claude-haiku                   claude-haiku-4-5-20251001
minimax-m2.5-highspeed         MiniMax-M2.5-highspeed
openrouter/free-large          openrouter/openai/gpt-oss-120b:free
```

**Marker:** SUSPECT (contradicts seed; daemon-state-dependent)

---

### G34: Cosmetics — don't chase these

| Trap | Reality |
|---|---|
| `doctor` → `rust: fail`, `node: warn`, `all_ok: false` | Dev-toolchain checks, irrelevant at runtime. **VERIFIED** — normal on a healthy install. Never `doctor --repair` for these. |
| `Agent is unresponsive` with no follow-up | Cosmetic. Only escalate if `marked as Crashed` + `Auto-recovering` follow (G5). **VERIFIED** |
| CLI help says "FangHub" | Product is **ClawHub** (clawhub.ai); endpoints are `/api/clawhub/*`. Naming drift only. **VERIFIED** — binary contains `browseClawHub()`, `installFromClawHub()`, `Browse ClawHub`. |
| `channel list` shows 8 of 44 channels | `/api/channels` is the truth. 44 types are compiled in. **UPSTREAM/seed** |
| `status` → `Data dir: ?` | **Does NOT reproduce on 0.6.9.** Prints `Data dir: /home/kyzdes/.openfang/data`. Seed entry is wrong — dropped. **VERIFIED** |
| `Unparseable cron expression, defaulting to 300s` | Real, but no occurrences here (`cron_jobs.json` is `[]`). A bad cron spec silently becomes **every 5 minutes** — dangerous, cf. G4. **UNVERIFIED locally** |
| `CHANGELOG.md` stops at 0.5.10 | Stale. Real notes only on GitHub Releases. **UPSTREAM** |

---

## Two structural facts that generate most of the above

1. **Disk beats DB, always.** Boot reconciles disk → DB for agents (G11), workflows (G26), and
   models (G8/G9). Every "my change reverted" bug is this. **Edit files, stop the daemon first.**
2. **The CLI is a kernel, not a client.** With the daemon down, `status`/`models`/`skill`/`agent list`
   boot a full in-process kernel and **write** — +9 Merkle-chained audit rows and 30 agent rewrites
   each (G12). "Read-only investigation" of a stopped OpenFang is a myth — use the `curl` health
   probe for liveness, `sqlite3 …?mode=ro` + `LIMIT` for facts. (`health` and `doctor --json` are
   the only side-effect-free CLI calls.)

And one about the project: **v0.6.9 is the end of the line.** Upstream `main` last moved 2026-05-12;
"still maintained?" issues (#1240, #1214) are unanswered. Nothing marked UPSTREAM here will ever be
fixed. The active successor fork is **https://github.com/librefang/librefang** (v2026.7.11) — the
only path to fixes for #1252, #1212, #1195, #1192.

## The safe-operations contract

```bash
# ALLOWED (true reads)
sqlite3 "file:/home/kyzdes/.openfang/data/openfang.db?mode=ro" "SELECT ... LIMIT 20"
curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:4200/api/health  # G12 — liveness
curl -s --max-time 5 http://127.0.0.1:4200/api/...          # GET only, daemon up
grep -rl PAT /home/kyzdes/.openfang --include="*.toml" | head -20
sed -r 's/bot[0-9]{8,10}:[A-Za-z0-9_-]{35}/bot<REDACTED>/g; s/\x1b\[[0-9;]*m//g' \
  daemon-start.log | grep PAT | tail -50            # G3a redactor + G23 ANSI strip — keep BOTH
strings /home/kyzdes/.openfang/bin/openfang | grep -E PAT | head -c 2000
openfang health · openfang doctor --json                    # delta 0 audit rows — VERIFIED

# ALLOWED but WRITES when the daemon is down (G12) — budget 13s, +9 audit rows AND 30 agent
# rewrites EACH, into an append-only Merkle chain you cannot undo. Use the curl probe instead.
openfang status · openfang models aliases · openfang skill list · openfang agent list

# NEVER without an explicit human go-ahead
start · stop · --yolo · agent set/kill · config set/unset/edit · vault set/init
skill install · hand activate · cron/trigger/workflow create/delete/run
reset · uninstall · doctor --repair · any POST/PUT/DELETE to 127.0.0.1:4200
grep -r from ~ or . or /        # G1 — this OOMs the machine
nohup openfang start ... & disown  # G2 — this does not survive systemd-oomd
systemd-run --user --scope ... openfang start   # G2a — BLOCKS; not a detach. Omit --scope.
systemd-run ... openfang start > log 2>&1       # G2b — logs systemd-run, not the daemon
grep -i telegram ~/.openfang/daemon-start.log   # G3a — prints a LIVE bot token. Redact first.
openfang start | head           # G3 — this SIGPIPEs the daemon dead
```
