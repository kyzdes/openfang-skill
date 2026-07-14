---
allowed-tools: Bash(openfang stop:*), Bash(openfang status:*), Bash(openfang health:*), Bash(systemd-run:*), Bash(systemctl:*), Bash(cp:*), Bash(curl:*), Bash(grep:*), Bash(pgrep:*), Bash(export:*), Bash(sleep:*), Read
description: Safely restart the OpenFang daemon — foreground/oomd-proof. DESTRUCTIVE to running agents; needs explicit user intent.
disable-model-invocation: false
---

Restart the OpenFang daemon **safely**. This is destructive: it kills 30 running agents, interrupts
any in-flight work, and re-spawns everything from disk.

## Gate — do not skip

Run this **only** when the user has explicitly asked to restart, or when a change genuinely requires
it (model registry / config edits, which have **no reload command**). Never restart just to inspect
something — `/openfang-status` is read-only and answers most questions.

Before touching anything, tell the user what a restart costs:
- all 30 agents are killed and re-spawned
- `session_repair` runs and may drop leading assistant turns
- `Agent TOML on disk differs from DB, updating` fires for all 30 — **disk wins, so any runtime
  change made via `agent set` is reverted**

## 🚨 The three traps that make a naive restart fail

1. **`openfang start` runs in the FOREGROUND.** It does not daemonize. If you run it as a normal
   Bash call it blocks until timeout.
2. **Never pipe it.** `openfang start | head` sends SIGPIPE and **kills the daemon**. Verified.
3. **`nohup … & disown` is NOT enough.** `disown` does not move the process out of the systemd
   cgroup. When systemd-oomd killed the terminal scope
   (`app-gnome-Alacritty-4436.scope: Failed with result 'oom-kill'`), the daemon died with it.
   **Verified on this machine.** Use `systemd-run --user --unit=openfang` — a transient
   **service**, which puts the daemon in its own cgroup unit that outlives the terminal.
   **NOT a `--scope`:** a scope runs as a child of the calling shell and **blocks**, hanging the
   tool call and re-creating the bug above.
4. **Never use a shell redirect (`> log 2>&1 &`) on `systemd-run`.** It captures **systemd-run's
   own** output, not the daemon's — the daemon is already detached and its output goes wherever
   systemd sends it. You get an almost-empty log and no way to tell healthy from failed.
   Use `-p StandardOutput="truncate:…"`. Also: **the daemon logs to stderr**, so a bare `> log`
   without `2>&1` captures the wrong stream. → `gotchas.md` G2b

## Procedure

```bash
export PATH="$HOME/.openfang/bin:$PATH"
cd "$HOME/.openfang"

# 1. Snapshot the model registry BEFORE stopping — the daemon may rewrite it on stop
cp custom_models.json custom_models.json.prestop

# 2. Stop  (skip if `curl … /api/health` already returns 000 — it is already down)
openfang stop

# 3. Did the daemon clobber the registry? If you had edited it, restore your version NOW,
#    while nothing is running. (Compare, then decide — do not blindly overwrite.)
#    diff custom_models.json custom_models.json.prestop
#    cp custom_models.json.prestop custom_models.json    # only if the daemon overwrote your edit

# 4. Start as its OWN transient systemd SERVICE — survives the terminal dying.
#    THE CANONICAL COMMAND — byte-identical to SKILL.md #1 and daemon-lifecycle.md.
#    NO shell redirect, NO --scope, NO nohup. `~` is NOT expanded inside file: — use $HOME.
systemctl --user reset-failed openfang 2>/dev/null   # --unit fails if the name is taken/failed
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start

# 5. Poll for readiness — never sleep blind (never pipe `start` itself)
for i in $(seq 30); do
  [ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:4200/api/health)" = 200 ] \
    && { echo "up after ${i}"; break; }; sleep 2
done
curl -s -o /dev/null -w 'health_http=%{http_code}\n' --max-time 5 http://127.0.0.1:4200/api/health
```

If `systemd-run` is unavailable, the fallback is a proper `systemd --user` unit — **not** `nohup`.

## Verify — all three must pass

```bash
# a) Daemon alive
curl -s --max-time 5 http://127.0.0.1:4200/api/health/detail

# b) Telegram bridge came up
grep -iE "Telegram bot .* connected|telegram channel bridge started" \
  "$HOME/.openfang/daemon-start.log" | tail -2

# c) Embedding driver picked up the config
grep -i "Embedding driver configured" "$HOME/.openfang/daemon-start.log" | tail -1
```

Expected, respectively: `"status":"ok"`; the two Telegram lines; and
`Embedding driver configured from memory config provider=ollama model=mxbai-embed-large`.

If (c) is missing you will see instead:
`No embedding provider available. Memory recall will use text search only.` → `references/memory-embeddings.md`

## After

Report to the user: daemon up/down, agent count, active provider+model, and whether the Telegram
bridge and embedding driver came back. If any of the three checks failed, name the reference file
rather than improvising.

`scripts/safe-restart.sh` implements this same sequence non-interactively; it refuses to run unless
`OPENFANG_CONFIRM=1` is set.
