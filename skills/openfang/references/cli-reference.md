# OpenFang CLI reference (v0.6.9)

**Read this when** you must run any `openfang` command: to get the exact signature/flags, to know
whether the daemon must be up, to avoid a destructive command, or to explain why a command printed
nothing / printed garbage / lied. Covers all 40 top-level commands and every subcommand.

Binary: `/home/kyzdes/.openfang/bin/openfang` (on `PATH`; `command -v openfang` → same path). VERIFIED.
Version: `openfang 0.6.9` (`openfang system version`). VERIFIED.

---

## The six things that waste the most time

1. **Most read commands have TWO code paths, and they disagree.** When the daemon is up the CLI
   talks HTTP; when it is down the CLI boots an **ephemeral in-process kernel**. The same command
   produces different — sometimes wrong — output depending on which path ran. `models aliases` and
   `status`'s `Data dir` are **correct in-process and broken over HTTP**. See
   [The two-path model](#the-two-path-model-the-central-mental-model). This is the single biggest
   source of confusion in this CLI.
2. **`openfang logs` tails the wrong file and silently prints nothing.** It reads
   `~/.openfang/tui.log` (the TUI's tracing sink), not the daemon log. On this install `tui.log` is
   0 bytes → **empty output, exit 0**. The real daemon log only exists because the operator
   redirected it: `~/.openfang/daemon-start.log` (797 KB). Use `tail` on that file instead. VERIFIED.
3. **`openfang start` runs in the FOREGROUND and dies on SIGPIPE.** Piping it to `head` kills the
   daemon. VERIFIED. **Do NOT detach it with `nohup … & disown`** — `disown` does not leave the
   systemd cgroup, so when *anything else* in the terminal scope OOMs, systemd tears the scope down
   and the daemon gets SIGTERM with it (VERIFIED — it happened, 2026-07-14 10:36:41). Launch it as a
   **transient systemd service — no `--scope`**, which blocks and re-parents to your shell:
   ```bash
   systemd-run --user --unit=openfang --collect \
     -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
     ~/.openfang/bin/openfang start
   ```
   Canonical command — identical in SKILL.md #1 and `daemon-lifecycle.md`. `StandardError=inherit`
   is not optional decoration: **the daemon logs to stderr**, so omitting it risks an empty-looking log.
   (`StandardError` defaults to `inherit`, so that one flag captures both streams — VERIFIED.)
   Full procedure, and why the log location depends on the launch method: `daemon-lifecycle.md`.
4. **`doctor` and `status` exit 0 even when they report failure.** `doctor` exits 0 with
   `"all_ok": false`; `status` exits 0 with `Daemon: NOT RUNNING`. **Only `openfang health` exits
   nonzero when the daemon is down.** Never gate a script on `doctor`'s or `status`'s exit code.
   VERIFIED.
5. **`openfang status` is not read-only.** With the daemon down it boots an in-process kernel and
   writes **+9 rows** to the production Merkle audit trail, every single call (VERIFIED: 977 → 986).
   `doctor --json` and `health` are free. See [Which commands boot a kernel](#which-commands-boot-a-kernel-daemon-down-verified-on-this-install).
6. **Addressing is inconsistent: `agent chat` / `agent kill` / `agent set` demand a UUID; almost
   everything else takes a name.** See [Addressing](#addressing-uuid-vs-name).

---

## Global invariants

**Every command accepts `--config <PATH>`** (overrides `~/.openfang/config.toml`). VERIFIED — present
in all 90+ `--help` outputs probed.

Other globals: `-h/--help` (any level), `-V/--version` (root only).

**Environment variables** (UPSTREAM — `docs/cli-reference.md` §Global Options):

| Var | Effect |
|---|---|
| `RUST_LOG` | Log verbosity, e.g. `info`, `debug`, `openfang_kernel=trace` |
| `OPENFANG_AGENTS_DIR` | Override the agent templates directory |
| `EDITOR` / `VISUAL` | Editor for `config edit`; falls back to `vi` on Unix |

### Exit codes

| Code | Meaning | Source |
|---|---|---|
| `0` | Success — **including `doctor` with failures and `status` with the daemon down** | VERIFIED |
| `1` | General error; also the uniform "requires a running daemon" refusal | VERIFIED |
| `101` | **Rust panic — in practice a SIGPIPE abort when you truncate stdout** | VERIFIED (see below) |
| `130` | Interrupted by a second `Ctrl+C` (force exit) | UPSTREAM (§Exit Codes) |

**The SIGPIPE trap.** OpenFang does not restore the default `SIGPIPE` disposition, so Rust's stdout
writer panics when the reader closes early. Observed once: `openfang agent list 2>/dev/null | head -8`
→ table printed in full but `PIPESTATUS[0]=101`. It is a **race**, not deterministic — the same
command with `head -3` and with no pipe both exited 0. Consequence for `openfang start`: an early
pipe close **kills the daemon**. Do not pipe long-output openfang commands into `head`; redirect to
a file and read the file. VERIFIED.

```bash
# WRONG — may abort with 101, and for `start` kills the daemon
openfang agent list | head -8

# RIGHT
openfang agent list > /tmp/agents.txt 2>/dev/null; head -8 /tmp/agents.txt
```

### Daemon auto-detect

UPSTREAM (`docs/cli-reference.md` §Daemon Auto-Detect), consistent with local observation:

1. The daemon writes `~/.openfang/daemon.json` with its listen address on start.
2. The CLI reads it, then sends `GET http://<listen>/api/health` with a **2-second timeout**.
3. Success → HTTP path. Failure (missing/stale `daemon.json`, timeout) → in-process fallback for
   commands that support it; the rest exit 1.

VERIFIED: with the daemon stopped cleanly, `~/.openfang/daemon.json` does not exist
(`ls: cannot access '/home/kyzdes/.openfang/daemon.json': No such file or directory`).
A **stale** `daemon.json` after a crash/OOM does **NOT** block `start`: the guard validates the pid
against a live, responding process and otherwise logs `Removing stale daemon info file` and starts
normally. **Do not reach for `openfang doctor --repair`** — it is never required here and it can
regenerate `config.toml` from `detect_best_provider()`. → `daemon-lifecycle.md`, `gotchas.md` G24
(retracted). *(This line previously said the opposite.)*

---

## The two-path model (the central mental model)

```
                     ┌── daemon UP  ──> HTTP to 127.0.0.1:4200  ──> "live" answer
openfang <cmd>  ─────┤
                     └── daemon DOWN ──> ephemeral in-process kernel (boots, reads DB) ──> "cold" answer
                                     └── or: exit 1 "requires a running daemon"
```

**The in-process fallback is not free.** It performs a **full kernel boot**: loads config, configures
**4** fallback providers (VERIFIED: `grep -c "Fallback provider configured"` → 4 = gonka-2/3/4 +
nim-1; the default gonka-1 is not a "fallback"), applies **5** provider URL overrides (all 5
providers incl. gonka-1 — do not conflate the two counts), builds the model catalog (334 models),
loads 61 bundled skills + 9 hands, and **restores 30 agents — writing to the DB** (`Agent TOML on
disk differs from DB, updating` ×30). Takes ~1–3 s and floods **stderr** with tracing.
So a "read-only" `openfang status` is **not read-only against the database**. VERIFIED:

```bash
$ openfang status 2>/dev/null | head -8
  >> OpenFang Status (in-process)

  Agents:      30
  Provider:    gonka-1
  Model:       moonshotai/kimi-k2.6
  Data dir:    /home/kyzdes/.openfang/data
  Daemon:      NOT RUNNING
```

**Always `2>/dev/null`** on in-process commands — the useful output is on stdout, the kernel boot log
is on stderr.

### Which commands boot a kernel (daemon DOWN, VERIFIED on this install)

**This is the most operationally important table in this file.** With the daemon down, a command
does one of four things, and the difference is **whether it silently writes to your production
audit trail**. Getting this wrong is how this install went 887 → 986 audit rows.

| Class | Daemon down → | Kernel boot? | **Writes DB?** | Exit | Commands |
|---|---|---|---|---|---|
| **A** | answers "cold" | **YES ~1–3 s** | **YES — +9 audit rows, 30 manifests re-stamped** | 0 | `status`, `gateway status`, `agent list`, `agent new`, `agent spawn`, `agent kill`, `skill list`, `channel list`, `models list\|aliases\|providers`, `vault list`, `integrations`, `completion`, `chat`, `message` |
| **B** | **refuses** | no | no | **1** | `cron list`, `sessions`, `approvals list`, `hand list`, `security status`, `security audit`, `devices list`, `webhooks list`, `trigger list`, `workflow list`, `memory list`, `qr`, `channel test` |
| **C** | answers | no | no | 0 | `system version`, `system info`, **`doctor`** |
| **D** | answers | no | no | **1** | **`health`**, `health --json` |

**Class A is the trap. Class B is safe by accident** — it refuses before it can cost you anything.
**Prefer C and D when the daemon is down.**

**`doctor` is class C, not A — corrected here.** Earlier revisions listed it as booting a kernel.
It does not. VERIFIED, measured around a live run:
```bash
$ sqlite3 ~/.openfang/data/openfang.db 'SELECT COUNT(*) FROM audit_entries;'   # 986
$ /usr/bin/time -f "elapsed=%es" openfang doctor --json 2>doctor.err >/dev/null
elapsed=0.01s
$ wc -c < doctor.err        # 135  — ONE line, not a kernel boot flood
$ head -1 doctor.err
... INFO openfang_skills::registry: Loaded 61 bundled skill(s)
$ sqlite3 ~/.openfang/data/openfang.db 'SELECT COUNT(*) FROM audit_entries;'   # 986 — delta 0
```
**0.01 s, 135 bytes of stderr, audit delta 0, DB mtime unchanged.** A real class-A boot takes
~1–3 s and floods stderr. `doctor` only loads the skills registry. **`doctor --json` and `health`
are the two commands you can run freely against a down daemon.**

**Class A example** — note this cost +9 audit rows to produce:
```bash
$ openfang agent list 2>/dev/null | head -3
ID                                     NAME                 STATE        CREATED
-------------------------------------------------------------------------------------
054d89cb-4cc7-4771-8f3e-87735dd7d2b1 tutor                Running      2026-07-13 16:15
```
The `STATE` column reads `Running` **while the daemon is down** — the in-process kernel reports its
own freshly-restored agents, not reality. Do not read liveness out of class A output; use `health`.

**Before running any class-A command with the daemon down, ask whether `doctor --json` answers your
question instead.** If you must, snapshot the count first so the damage is at least known:
```bash
sqlite3 ~/.openfang/data/openfang.db 'SELECT COUNT(*) FROM audit_entries;'
```

**B. Refuses, exit 1** — verbatim message (greppable):

```
  ✘ `openfang cron list` requires a running daemon
    fix: Start the daemon: openfang start
  hint: Or try `openfang chat` which works without a daemon
```

Confirmed refusers: `cron list`, `sessions`, `approvals list`, `hand list`, `security status`,
`security audit`, `devices list`, `webhooks list`, `trigger list`, `workflow list`,
`memory list`, `qr`. `channel test` has its own string: `Channel test requires a running daemon.
Start with: openfang start`.

**C. Answers, no kernel boot, exit 0** — `system version`, `system info` (prints
`Daemon:      NOT RUNNING`), and `doctor` (proof above).

**D. Answers, no kernel boot, exit 1** — `health`, the only reliable liveness probe:

```bash
$ openfang health; echo $?
  ✘ Daemon is not running.
  hint: Start it with: openfang start
1
$ openfang health --json
{"error":"daemon not running"}
```

### Correct liveness check

```bash
openfang health --json    # exit 1 + {"error":"daemon not running"} when down; USE THIS
# NEVER: `openfang doctor; echo $?`  or  `openfang status; echo $?` — always 0
```
**Do not probe liveness with `status --json | jq -r .daemon`.** It reports `false` correctly, but
it is **class A**: with the daemon down it costs +9 audit rows *every poll*. In a retry loop that is
how you write hundreds of rows. `health` is free and gives a usable exit code.

The zero-cost, zero-kernel probe that does not involve the CLI at all (`000` = down):
```bash
curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:4200/api/health
```

---

## DANGER — destructive commands

**Never run any of these against a production install without explicit, specific user consent.**

| Command | What it does | Why it is dangerous |
|---|---|---|
| `openfang reset [--confirm]` | Resets local config and state | **Wipes config + DB.** `--confirm` skips the prompt. |
| `openfang uninstall [--confirm] [--yes] [--keep-config]` | Removes OpenFang entirely | **Irreversible.** `--keep-config` spares `config.toml`, `.env`, `secrets.env` only. |
| `openfang start --yolo` | **Auto-approves ALL tool calls** | Every agent (30 here) gets unattended `shell_exec` with `network=["*"]`. Full RCE-by-LLM. |
| `openfang doctor --repair` | "Auto-fix" — creates missing dirs/config, clears stale `daemon.json` | **Writes.** Its diagnosis is wrong on this install (see below), so its repairs are untrustworthy. |
| `openfang agent kill <UUID>` | Kills an agent | Takes a UUID — **easy to hit the wrong agent**. |
| `openfang agent set <UUID> model <VAL>` | Mutates a live agent | **Reverted on next boot** — `Agent TOML on disk differs from DB, updating` re-syncs from disk. Edit `agents/<name>/agent.toml` instead. |
| `openfang config set <K> <V>` / `config unset <K>` | Rewrites `config.toml` | **Strips ALL TOML comments** (re-serializes). VERIFIED+UPSTREAM. |
| `openfang stop` / `gateway stop` | Stops the daemon | The daemon may **rewrite `custom_models.json` on stop**. |
| `openfang vault init` | Initializes the vault | Changes the credential model for the whole install. |
| `openfang skill install`, `hand activate/install`, `cron create/delete`, `trigger create/delete`, `workflow create/update/delete/run`, `channel enable/disable`, `add`, `remove` | Mutate state | Not read-only. Ask first. |

Read-only and safe: `--help` anywhere, `list`/`show`/`get`/`info`/`status`, `doctor` **without**
`--repair`, `health`, `security audit|status|verify`, `models *`, `sessions`, `completion`,
`integrations`, `system *`.

---

## Command reference

Legend for **Daemon**: `req` = exits 1 without it · `opt` = falls back to in-process kernel ·
`no` = never needs it.

### Lifecycle

| Command | Daemon | Notes |
|---|---|---|
| `openfang init [--quick]` | no | Creates `~/.openfang/` + default config. `--quick`: no prompts, writes config + `.env` (CI). |
| `openfang setup [--quick]` | no | "Quick non-interactive initialization". `--quick` is documented as "same as `init --quick`". |
| `openfang onboard [--quick]` | no | Interactive onboarding wizard; `--quick` = non-interactive. |
| `openfang configure` | no | Interactive wizard for credentials and channels. |
| `openfang start [--yolo]` | — | **FOREGROUND.** **DANGER `--yolo`.** Writes `daemon.json`. |
| `openfang stop` | req | Prints `No running daemon found` otherwise. |
| `openfang gateway start\|stop\|status [--json]` | — | Aliases of `start`/`stop`/`status`. `gateway status` adds `--json`, and inherits `status`'s **+9-audit-row** cost when down. |
| `openfang status [--json]` | opt | **Exit always 0.** **WRITES +9 audit rows when the daemon is down** (class A). See the `Data dir` trap below. |
| `openfang health [--json]` | no | **The only correct liveness probe** (exit 1 when down). |
| `openfang doctor [--json] [--repair]` | no | Exit always 0 — parse `.all_ok`. **No kernel boot, no DB write** (0.01 s — VERIFIED); safe when down. 19 checks. **DANGER `--repair`.** |
| `openfang reset [--confirm]` | no | **DANGER.** |
| `openfang uninstall [--confirm] [--keep-config]` | no | **DANGER.** `--yes` accepted as an alias of `--confirm`. |
| `openfang system info [--json]` \| `system version [--json]` | no | `info` prints `Daemon: NOT RUNNING`, exit 0. |
| `openfang logs [--lines N] [-f/--follow]` | no | Default `--lines 50`. **BROKEN — tails `tui.log`.** |
| `openfang completion <SHELL>` | no | `bash`, `elvish`, `fish`, `powershell`, `zsh`. |
| `openfang tui` | opt | Full-screen TUI. Redirects tracing to `~/.openfang/tui.log` (UPSTREAM §TUI). |
| `openfang dashboard` | req | Opens the web dashboard in a browser. |
| `openfang mcp` | opt | MCP server over stdio. This is what `.mcp.json` wraps. |
| `openfang migrate --from <FROM> [--source-dir DIR] [--dry-run]` | no | `--from` ∈ `openclaw`, `langchain`, `autogpt`. **Use `--dry-run` first.** |

### Agents

| Command | Daemon | Notes |
|---|---|---|
| `openfang agent new [TEMPLATE]` | opt | Interactive picker if `TEMPLATE` omitted (e.g. `coder`, `assistant`). |
| `openfang agent spawn <MANIFEST>` | opt | Path to an agent manifest **TOML**. |
| `openfang agent list [--json]` | opt | `--json` emits an array of objects (`id`, `name`, `created_at`, …). |
| `openfang agent chat <AGENT_ID>` | req | **UUID only.** |
| `openfang agent kill <AGENT_ID>` | req | **UUID only. DANGER.** |
| `openfang agent set <AGENT_ID> <FIELD> <VALUE>` | req | **UUID only.** `FIELD` documented as `model` only. **DANGER — reverted on restart.** |
| `openfang chat [AGENT]` | opt | **Name or ID.** The documented daemon-free escape hatch. |
| `openfang message <AGENT> <TEXT> [--json]` | opt | **Name or ID.** One-shot; the scriptable form of `chat`. |
| `openfang sessions [AGENT] [--json]` | req | Optional name/ID filter. |

### Workflows / triggers / cron / webhooks

| Command | Daemon | Notes |
|---|---|---|
| `openfang workflow list` | req | No `--json`. |
| `openfang workflow create <FILE>` | req | **JSON** file (agents use TOML — do not mix them up). |
| `openfang workflow get <WORKFLOW_ID>` | req | UUID. |
| `openfang workflow update <WORKFLOW_ID> <FILE>` | req | UUID + JSON file. |
| `openfang workflow delete <WORKFLOW_ID>` | req | **Deleted workflows reappear after restart** (UPSTREAM #1192). |
| `openfang workflow run <WORKFLOW_ID> <INPUT>` | req | `INPUT` is free text. |
| `openfang trigger list [--agent-id <UUID>]` | req | |
| `openfang trigger create <AGENT_ID> <PATTERN_JSON> [--prompt <P>] [--max-fires <N>]` | req | UUID. `--prompt` default `"Event: {{event}}"`; `--max-fires` default `0` = unlimited. Patterns: `'{"lifecycle":{}}'`, `'{"agent_spawned":{"name_pattern":"*"}}'`. |
| `openfang trigger delete <TRIGGER_ID>` | req | UUID. |
| `openfang cron list [--json]` | req | |
| `openfang cron create <AGENT> <SPEC> <PROMPT> [--name <N>]` | req | **Name or ID.** `SPEC` e.g. `"0 */6 * * *"`. Name auto-generated if omitted. |
| `openfang cron delete\|enable\|disable <ID>` | req | Job ID. |
| `openfang webhooks list [--json]` | req | |
| `openfang webhooks create <AGENT> <URL>` | req | **Name or ID.** |
| `openfang webhooks delete <ID>` \| `webhooks test <ID>` | req | Webhook ID. |

**Unparseable cron specs do not error — they silently default to 300 s** (`Unparseable cron
expression, defaulting to 300s`). Verify with `cron list` after creating. VERIFIED (log string).

### Models / config / credentials

| Command | Daemon | Notes |
|---|---|---|
| `openfang models list [--provider <P>] [--json]` | opt | 334 models, 143 available, 6 local on this install. |
| `openfang models aliases [--json]` | opt | 89 aliases. **Table BROKEN over HTTP; correct in-process.** |
| `openfang models providers [--json]` | opt | Columns: PROVIDER, AUTH, MODELS, BASE URL. |
| `openfang models set [MODEL]` | opt | Interactive picker if omitted. Writes config. |
| `openfang config show` | opt | |
| `openfang config edit` | no | Opens `$EDITOR`/`$VISUAL`, else `vi`. |
| `openfang config get <KEY>` | opt | Dotted path. Missing key → `  ✘ Key not found: <KEY>`. |
| `openfang config set <KEY> <VALUE>` | opt | **DANGER — strips comments.** **Type is inferred from the EXISTING value** (UPSTREAM) — you cannot reliably create a new key of a new type. |
| `openfang config unset <KEY>` | opt | **DANGER — strips comments.** |
| `openfang config set-key <PROVIDER>` | no | Prompts, writes **`~/.openfang/.env`** — *not* `secrets.env`. See the secrets trap. |
| `openfang config delete-key <PROVIDER>` | no | Removes from `.env`. |
| `openfang config test-key <PROVIDER>` | no | Tests provider connectivity. |
| `openfang vault init\|set <KEY>\|list\|remove <KEY>` | opt | Uninitialized here: `vault list` → `Vault not initialized. Run: openfang vault init`, exit 0. |
| `openfang auth hash-password` | no | Argon2id hash for `[dashboard] password_hash`. |

VERIFIED `config get`:

```bash
$ openfang config get default_model.provider 2>/dev/null      # gonka-1
$ openfang config get api_listen 2>/dev/null                  # 127.0.0.1:4200
$ openfang config get memory.embedding_provider 2>/dev/null   # ollama
$ openfang config get nonexistent.key 2>/dev/null             #   ✘ Key not found: nonexistent.key
```

### Skills / hands / channels / integrations

| Command | Daemon | Notes |
|---|---|---|
| `openfang skill list` | opt | **BROKEN — always `No skills installed.`** |
| `openfang skill install <SOURCE>` | opt | Name, local path, or git URL. Help says "FangHub"; the real registry is **ClawHub** (`clawhub.ai`). |
| `openfang skill remove <NAME>` | opt | |
| `openfang skill search <QUERY>` | opt | Hits ClawHub. |
| `openfang skill create` | no | Scaffold. Same as `openfang new skill`. |
| `openfang new <KIND>` | no | `KIND` ∈ `skill`, `integration`. |
| `openfang hand list` | **req** | 9 bundled hands exist but you cannot list them without the daemon. |
| `openfang hand active` | req | |
| `openfang hand install <PATH>` | req | Directory containing `HAND.toml`. |
| `openfang hand activate <ID> [-n/--name <NAME>]` | req | `--name` **required to run multiple instances of the same hand**. |
| `openfang hand deactivate <ID>` \| `info <ID>` \| `check-deps <ID>` \| `install-deps <ID>` | req | Hand ID, e.g. `clip`, `lead`, `researcher`, `browser`. |
| `openfang hand pause <ID>` \| `hand resume <ID>` | req | **`ID` here is the INSTANCE ID from `hand active`**, not the hand ID. Different argument from every other `hand` subcommand. |
| `openfang hand config <ID> [--get K] [--set K=V]... [--unset K]... [--list]` | req | `--set`/`--unset` repeatable. `--list` is the default with no flags. |
| `openfang channel list` | opt | **Shows only 8 of 44 compiled-in channels** — `GET /api/channels` is the truth. |
| `openfang channel setup [CHANNEL]` | opt | Picker if omitted. |
| `openfang channel test <CHANNEL>` | req | Distinct error string (see above). |
| `openfang channel enable\|disable <CHANNEL>` | req | |
| `openfang integrations [QUERY]` | opt | Lists all if `QUERY` omitted. |
| `openfang add <NAME> [--key <KEY>]` | opt | One-click MCP setup. `--key` claims to store in **the vault — which is uninitialized here**. |
| `openfang remove <NAME>` | opt | |

### Security / memory / devices / approvals

| Command | Daemon | Notes |
|---|---|---|
| `openfang security status [--json]` | req | |
| `openfang security audit [--limit N] [--json]` | req | Default `--limit 20`. 575 audit rows here. |
| `openfang security verify` | req | Verifies the Merkle chain. |
| `openfang memory list <AGENT> [--json]` | req | **KV store only — not the 60 semantic `memories` rows.** Name or ID. |
| `openfang memory get <AGENT> <KEY> [--json]` | req | |
| `openfang memory set <AGENT> <KEY> <VALUE>` | req | Mutates. |
| `openfang memory delete <AGENT> <KEY>` | req | Mutates. |
| `openfang devices list [--json]` \| `pair` \| `remove <ID>` | req | |
| `openfang qr` | req | Pairing QR. |
| `openfang approvals list [--json]` \| `approve <ID>` \| `reject <ID>` | req | |

**`openfang memory` ≠ agent memory.** It is the `kv_store` table (5 rows here). The semantic
`memories` table is not reachable from the CLI at all — use `GET /api/…` or sqlite3.

---

## Broken / misleading commands (each VERIFIED unless noted)

### 1. `logs` tails the TUI log

```bash
$ openfang logs --lines 3; echo "exit=$?"
exit=0            # ← nothing printed
$ ls -la ~/.openfang/*.log
-rw-rw-r-- 1 kyzdes kyzdes 796982 Jul 14 10:36 /home/kyzdes/.openfang/daemon-start.log
-rw-rw-r-- 1 kyzdes kyzdes      0 Jul 14 12:01 /home/kyzdes/.openfang/tui.log
```
The only `.log` path in the binary is `/.openfang/tui.log`
(`strings openfang | grep -oE '[A-Za-z_./-]*\.log' | sort -u`). UPSTREAM confirms tui.log is the
**TUI's** sink: *"Tracing output is redirected to `~/.openfang/tui.log` to avoid corrupting the
terminal display."* `openfang logs` is **absent from upstream `docs/cli-reference.md` entirely**.
**Use `tail -n 50 ~/.openfang/daemon-start.log` instead** (that file exists only because the operator
redirected `start`'s output there — there is no default daemon log).

### 2. `skill list` shows nothing despite 61 bundled skills

```bash
$ openfang skill list 2>/dev/null
No skills installed.
```
Yet the same invocation's boot log says `Loaded 61 bundled skill(s)`. The list path enumerates only
**user** skills; there is no `~/.openfang/skills/` here (bundled skills are compiled into the
binary; per-agent user skills live in `workspaces/<agent>/skills/`). `GET /api/skills` returns empty
too. **Upstream `docs/cli-reference.md` explicitly claims the opposite** — *"Loads skills from
`~/.openfang/skills/` plus bundled skills compiled into the binary"* — so the doc is wrong, not just
the output. To enumerate skills, use the `skill_list` **tool** from inside an agent.

### 3. `models aliases` — broken over HTTP, correct in-process

With the daemon **down** the table is fine (89 aliases):

```bash
$ openfang models aliases 2>/dev/null | head -4
ALIAS                          RESOLVES TO
------------------------------------------------------------
mixtral                        mixtral-8x7b-32768
gpt4                           gpt-4o
```
The in-process `--json` is a **flat map**: `{"abab7":"abab7-chat","claude-code":"claude-code/sonnet",…}`.
The daemon endpoint `/api/models/aliases` returns an **envelope** (`{"aliases":{…}}`), and the table
renderer walks the envelope's keys — producing one junk row.
**SUSPECT** (daemon-up half): reported broken in prior recon, not re-testable now — the daemon is
down and starting it is out of scope. **What would settle it:** with the daemon up, compare
`openfang models aliases` against `curl -s 127.0.0.1:4200/api/models/aliases | jq 'keys'`; if the
response's top level is `["aliases"]` rather than alias names, the envelope theory is confirmed.

### 4. `status` prints `Data dir: ?` — only over HTTP

In-process it is **correct**:
```
  Data dir:    /home/kyzdes/.openfang/data
```
and `status --json` → `"data_dir": "/home/kyzdes/.openfang/data"`. The binary contains exactly **one**
`Data dir` string, so both paths share the renderer; the `?` is the fallback when the daemon's
`/api/status` response omits `data_dir`. **SUSPECT** (daemon-up half) — same reason as #3.
**What would settle it:** `curl -s 127.0.0.1:4200/api/status | jq 'has("data_dir")'` with the daemon up.

### 5. `doctor` looks for the wrong secrets file and knows the wrong providers

```
  - .env file not found (create with: openfang config set-key <provider>)
  ...
  ○ Groq           (GROQ_API_KEY not set)
  ...
  ✘ No LLM provider API keys found!
```
**This is a false alarm.** There is no `.env`; this install keeps credentials in
`~/.openfang/secrets.env` (0600, holds `GONKA_1..4_API_KEY`, `NIM_1_API_KEY`,
`TELEGRAM_BOT_TOKEN`) and the daemon authenticates fine. The binary references
`/.openfang/secrets.env` (7 occurrences), so the **runtime loads it** — but `doctor` and
`config set-key` only know `.env` (UPSTREAM §Environment File documents only `.env`). Two secret
paths, no cross-awareness.

`doctor` also only probes a **hardcoded list of 11 providers** (Groq, OpenRouter, Anthropic, OpenAI,
DeepSeek, Gemini, Google, Together, Mistral, Fireworks, AWS Bedrock). The providers actually in use
here (`gonka-1..4`, `nim-1`) are not among them and can never satisfy it.

**Therefore `doctor --json`'s `"all_ok"` is permanently `false` on this install and is useless as a
gate.** Parse individual `checks[]` instead:

```bash
openfang doctor --json 2>/dev/null | jq -r '.checks[] | select(.status!="ok") | "\(.check) \(.status)"'
```
Real checks worth reading: `openfang_dir`, `config_file`, `config_deser`, `port`, `database`,
`disk_space`, `agent_manifests`.

**`config_deser` — NOT `config_syntax`.** Earlier revisions of this playbook named a
`config_syntax` check. **No such check exists**; grepping `doctor` output for it returns nothing.
The config-parse check is `config_deser`, and it does **not** appear next to `config_file` — it
lands after the `channel` rows. **The full 19-check list, re-derived from live `--json` output, is
in `daemon-lifecycle.md` §"`doctor`'s real check list"** — including the 3 benign `channel -> warn`
rows and the reason `rust -> fail` is the only `fail`. Do not re-derive it from prose; enumerate it:
```bash
openfang doctor --json 2>/dev/null | jq -r '.checks[] | "\(.check) \(.status)"'
```

### 6. Help says "FangHub"; the product is ClawHub

`skill install`/`skill search` help both say "FangHub". Binary string counts: `FangHub` → **2**,
`ClawHub` → **122**. The live registry is **ClawHub** (`clawhub.ai`, endpoints `/api/clawhub/*`).
The help text is vestigial.

### 7. `config set` reorders and de-comments the file

`config.toml` here is alphabetically sorted with 0 comment lines — the fingerprint of
re-serialization. **Back up before any `config set`:**
```bash
cp ~/.openfang/config.toml ~/.openfang/config.toml.bak-$(date +%Y%m%d%H%M)
```

---

## Addressing: UUID vs name

**Takes a UUID only** (get it from `openfang agent list`):
`agent chat` · `agent kill` · `agent set` · `trigger create <AGENT_ID>` · `trigger list --agent-id`

**Takes a name or an ID** (help string: *"Agent name or ID"*):
`chat [AGENT]` · `message <AGENT>` · `sessions [AGENT]` · `cron create <AGENT>` ·
`memory list|get|set|delete <AGENT>` · `webhooks create <AGENT>`

**Takes an opaque ID of its own kind:** `workflow *` (workflow UUID) · `trigger delete` (trigger
UUID) · `cron delete|enable|disable` (job ID) · `approvals approve|reject` (approval ID) ·
`devices remove` / `webhooks delete|test` (device/webhook ID) · `hand activate|info|check-deps`
(hand ID like `clip`) vs `hand pause|resume` (**instance** ID).

Resolve a name → UUID:
```bash
openfang agent list --json 2>/dev/null | jq -r '.[] | select(.name=="assistant") | .id'
# b09ea7eb-fb30-442f-934c-1a4049cdec16
```

---

## Scripting recipes

```bash
# Liveness (the ONLY correct probe)
if openfang health --json >/dev/null 2>&1; then echo up; else echo down; fi

# Machine-readable, kernel noise suppressed, no SIGPIPE risk
openfang agent list --json 2>/dev/null > /tmp/agents.json

# Which commands support --json (VERIFIED via --help):
#   status, doctor, health, sessions, message, agent list, gateway status,
#   models list|aliases|providers, cron list, approvals list, security status|audit,
#   memory list|get, devices list, webhooks list, system info|version
#   NOT: workflow list, trigger list, hand list, channel list, config show, skill list, integrations

# Start detached (never pipe `start`; never bare nohup — it dies with the terminal's cgroup)
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start

# Real daemon logs (NOT `openfang logs`)
tail -n 50 ~/.openfang/daemon-start.log
```

---

## Upstream documentation status

`docs/cli-reference.md` (1354 lines, RightNow-AI/openfang) documents **only ~40%** of the surface —
`init`, `start`, `status`, `doctor`, `dashboard`, `completion`, `agent new|spawn|list|chat|kill`,
`workflow list|create|run`, `trigger *`, `skill *`, `channel *`, `config show|edit|get|set|set-key|
delete-key|test-key`, `chat`, `migrate`, `mcp`.

**Undocumented upstream** (this file is the only reference): `logs`, `health`, `sessions`, `memory`,
`devices`, `webhooks`, `security`, `system`, `vault`, `models`, `gateway`, `approvals`, `cron`,
`hand`, `auth`, `qr`, `onboard`, `setup`, `configure`, `message`, `reset`, `uninstall`, `add`,
`remove`, `integrations`, `new`, `tui`, `stop`, `agent set`, `workflow get|update|delete`,
`config unset`.

The repo is **abandoned** — last `main` commit 2026-05-12 = v0.6.9 = the installed version. No CLI
fix is coming; treat the bugs above as permanent. Active successor fork:
`https://github.com/librefang/librefang`.

---

## Verification appendix

Every VERIFIED claim above came from these read-only commands on this install (2026-07-14, daemon
down, v0.6.9):

```bash
openfang --help                      # 40 top-level commands
openfang <cmd> --help                # all 18 subcommand groups
openfang <cmd> <sub> --help          # all ~80 leaf subcommands
openfang status [--json]             # in-process kernel, Data dir correct
openfang health [--json]             # exit 1
openfang doctor [--json]             # all_ok:false, .env not found
openfang agent list [--json]         # 30 agents
openfang skill list                  # "No skills installed."
openfang models aliases [--json]     # 89 aliases, table renders fine
openfang models providers            # AUTH=Missing for all 11 known providers
openfang config get <dotted.key>     # gonka-1 / 127.0.0.1:4200 / ollama
openfang logs --lines 3              # empty, exit 0
openfang completion bash             # bash completion emitted
strings -n 5 <binary> | grep …       # tui.log, secrets.env, FangHub/ClawHub counts
gh api repos/RightNow-AI/openfang/contents/docs/cli-reference.md   # upstream doc
```

**Not verifiable here (daemon is down; starting it was out of scope):** every daemon-up (HTTP-path)
behavior, including the `models aliases` envelope bug, `status`'s `Data dir: ?`, and all `req`
commands' real output. Those are marked SUSPECT or carry only their `--help` signature.
