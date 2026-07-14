---
name: openfang
description: >-
  Operate and troubleshoot OpenFang — an "Agent Operating System": a Rust CLI + daemon at
  `~/.openfang` that spawns and orchestrates AI agents over cloud inference (gonka, NVIDIA NIM).
  Use whenever a task touches the `openfang` binary, `~/.openfang/` (config.toml, secrets.env,
  custom_models.json, agents/, workspaces/, data/openfang.db, daemon-start.log), the OpenFang
  daemon/kernel/gateway on 127.0.0.1:4200, or its agents / models / providers / workflows /
  triggers / cron / channels / hands / skills / vault / memory — OR when the user says "openfang",
  "start/stop/restart the daemon", "agent is unresponsive", "add a model", "switch the model",
  "make this agent use model X", "pin a model to an agent", "the daemon is down", "agents look
  stuck", "the model registry", "openfang doctor", "the telegram bot is silent", "перезапусти openfang",
  "агент не отвечает", "добавь модель", "настрой openfang", "openfang молчит", "openfang не
  работает", "телеграм-бот не отвечает", "почини бота". CRITICAL CONTEXT: upstream is ABANDONED —
  last commit and last release are both v0.6.9 (2026-05-12), the installed version, so no fix is ever
  coming and every workaround here is permanent. Check liveness ONLY with `curl /api/health` —
  `openfang status` boots an in-process kernel and writes 9 irreversible audit rows when the daemon
  is down. Teaches the daemon lifecycle (start runs FOREGROUND; bare nohup does NOT survive
  systemd-oomd; use a transient systemd SERVICE, never `--scope`), the startup-cached model registry
  (edits need a restart; NO reload command), agent.toml + capabilities RBAC, providers and the
  fallback chain, cron/triggers/workflows/hands, memory + ollama embeddings, and a cost-ordered
  gotchas catalog verified against this install.
  NOT for LangChain, CrewAI, AutoGPT, Ollama-as-a-product, or LibreFang — OpenFang is a distinct
  Rust agent-OS.
metadata:
  short-description: Operate the OpenFang agent-OS — daemon, agents, models, automation, memory
  version: "0.1"
allowed-tools: Bash, Read, Grep, Glob
---

# OpenFang

OpenFang v0.6.9 — an "Agent Operating System": a Rust CLI (`~/.openfang/bin/openfang`, 66 MB) plus a
daemon that spawns and orchestrates AI agents. **Inference is cloud-based** — the local daemon is a
light orchestrator (~63 MB RAM), so the limit is the provider API and your quota, not local
hardware. This file is the **router**; the depth lives in `references/`.

## The seven things that waste the most time (read first)

1. **`openfang start` runs in the FOREGROUND — and bare `nohup` does not save it.**
   Piping it to `head` sends SIGPIPE and kills the daemon. `nohup … & disown` does **not** leave the
   systemd cgroup: when systemd-oomd killed the terminal scope (`app-gnome-Alacritty-4436.scope:
   Failed with result 'oom-kill'`), the daemon died with it. **Use a transient systemd _service_ —
   NOT `--scope`**, which runs as a child of your shell and **blocks**, hanging your tool call and
   dying with it. VERIFIED (probe units, 3.02 s vs 0.01 s — evidence in `daemon-lifecycle.md`).
   ```bash
   systemd-run --user --unit=openfang --collect \
     -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
     ~/.openfang/bin/openfang start
   ```
   **Use this exact string everywhere — every file in this playbook must match it.**
   `StandardOutput=file:` keeps `daemon-start.log` authoritative (drop it → the log silently moves to
   journald); `StandardError=inherit` captures the daemon's real output (**it logs to stderr** — a
   bare `> log` redirect grabs the wrong stream, VERIFIED). **No `~` inside `file:`** — systemd does
   not expand it. Unit taken or left `failed`? `systemctl --user reset-failed openfang` first.
   → `daemon-lifecycle.md`

2. **Never run `openfang mcp`, `openfang tui`, or `openfang dashboard` from a tool call.**
   `mcp` is a **stdio server that never exits**; its output buffers into your host process. This
   OOM-killed this machine at **12.3 GB**. Wire MCP into a client config instead. → `api-mcp.md`

3. **The model registry is cached in memory at boot. There is NO reload command.**
   Editing `custom_models.json` or `config.toml` does nothing until a restart — and the daemon may
   **rewrite `custom_models.json` on stop**. Safe order: **stop → write → start.** → `models-providers.md`

4. **`Agent is unresponsive` on idle agents is COSMETIC. `marked as Crashed → Auto-recovering` is NOT.**
   The second is upstream #1252 (hardcoded 60 s heartbeat) — a real loop firing an LLM call each
   round. Check it before blaming anything else. → `gotchas.md`

5. **"The bot is silent" is almost never the channel — and `Agent error for` is NOT the test.**
   `Telegram bot @X connected` + `bridge started` ⇒ Telegram is fine. But **do not clear the model
   just because `Agent error for` is absent** — it fires only for *inbound-message-triggered* calls;
   background/cron/heartbeat failures log elsewhere. Here the chain was 100% dead with **zero** of
   them. VERIFIED against `~/.openfang/daemon-start.log`:

   | String | Count | Means |
   |---|---|---|
   | `Agent error for` | **0** | inbound-triggered LLM failure — absence proves NOTHING |
   | `Fallback driver failed` | **178** | **any hit indicts the model chain. This is the real test.** |
   | `Agent loop failed` | 20 | background/cron path exhausted the chain |
   | ` ERROR ` | **0** | ← total inference failure logs at **WARN**. `grep ERROR` finds nothing. |

   **Never triage by log level.** → `channels.md`, then `models-providers.md`

6. **`[schedule]` in `agent.toml` has NO delivery. Want the result sent somewhere? Use cron.**
   `[schedule] periodic = { cron = "every 30m" }` makes the agent *think* every 30 min and post the
   result **nowhere** — a silent no-op that still burns tokens. Delivery (`delivery_targets`) exists
   only on the **cron subsystem**. Reaching for `[schedule]` is the natural mistake. → `automation.md`

7. **Upstream is dead — v0.6.9 is the last commit AND the last release.** No fix is coming. Do not
   file issues, wait for a release, or call these workarounds temporary. → `upstream-state.md`

## MUST NOT / CAN

**You MUST NOT:**
- pipe `openfang start` into anything (`| head` kills it via SIGPIPE)
- run `openfang mcp` / `tui` / `dashboard` from a tool call — they never return
- edit `custom_models.json` while the daemon is running (it may overwrite you on stop)
- run an unbounded recursive grep from `/home/kyzdes` — the home dir is 8.5 GB; the Grep tool buffers
  the whole result into memory and has OOM-killed this machine. Scope to `~/.openfang`, use `head_limit`.
- run `openfang reset`, `uninstall`, `doctor --repair`, or `config set` casually — DANGER tags in
  `cli-reference.md`. **`doctor --repair` is never a fix in this playbook**: it regenerates
  `config.toml` from `detect_best_provider()` and can silently replace this box's gonka/kimi setup.
- chase cosmetic heartbeat WARNs · restart a healthy daemon just to look at something

**You CAN (read-only) — but "read-only" ≠ "free". Two tiers:**

*Free at any time, daemon up or down (audit delta **0**, VERIFIED):*
- `curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:4200/api/health` ← **always start here**
- `openfang --help` / any `<cmd> --help`, `openfang health`, `openfang doctor --json` (never `--repair`)
- read anything under `~/.openfang` (⚠️ redact `daemon-start.log` — live token, see below);
  `sqlite3 … "SELECT … LIMIT 20"`
- `GET` on `127.0.0.1:4200` — **without a trailing slash** (`/api/agents/` 404s, `/api/agents` 200s)

*⚠️ **Costs +9 irreversible audit rows each when the daemon is DOWN** — cheap only once `health` is `200`:*
- `openfang status`, `agent list`, `agent new`, `agent spawn`, `agent kill` — each boots an
  in-process kernel and re-stamps 30 manifests. → `gotchas.md` G12
- `models list`, `models providers`, `sessions`, `logs`, `security audit`, **`stop`** — UNVERIFIED
  whether these boot a kernel too (`stop` on a down daemon fast-fails `No running daemon found`, but
  its audit cost is unmeasured). **Assume they cost until shown otherwise.** Recipes opening with
  `openfang stop`: skip it if `health` is already `000`.

**Offline substitutes** (daemon down, zero cost) — prefer these: agent UUID →
`sqlite3 -readonly ~/.openfang/data/openfang.db "SELECT id,name FROM agents LIMIT 5;"` · inventory →
`ls -1 ~/.openfang/agents` · config → read `config.toml` directly.

**Do not volunteer.** Working production install: 30 agents, a live Telegram bot. Do not restructure
it, "clean up" agents, migrate to LibreFang, or fix `doctor`'s false positives unasked. Diagnose,
report, wait.

## Fast path

**One command. Stop here until it answers.**
```bash
export PATH="$HOME/.openfang/bin:$PATH"
curl -s -o /dev/null -m 3 -w '%{http_code}\n' http://127.0.0.1:4200/api/health   # 000 = DOWN
```

**`000` → the daemon is down. That explains the *silence* (bot, "stuck" agents, dead API). It does
NOT mean a restart will fix it — spend one free grep on the second fault BEFORE restarting:**
```bash
sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log | grep -c 'Fallback driver failed'
```
**Non-zero ⇒ the model chain was dead when it went down; a restart gives you a bot that connects to
Telegram and still never answers** (here: **178**, 100% exhausted for the whole last session — #5).
Repoint it *while the daemon is already stopped* — you are inside the stop → edit → start rule (#3)
anyway, so it costs zero extra restarts. → `models-providers.md`, then `daemon-lifecycle.md`.
Beyond these two commands, run nothing else — see the cost tiers above.

⚠️ **Do NOT reach for `openfang status` to find out if it is up.** Down-daemon `status` (and `agent
list`/`new`/`spawn`/`kill`) **boots a full in-process kernel**: **+9 rows into `audit_entries`**, a
hash-chained Merkle trail, irreversible. VERIFIED: one run took **977 → 986**; live count **986**.
Δ887→977 = ten such boots already in the trail — *this front page* being followed. `curl` costs
zero. → `gotchas.md` G12

**Only once `health` returns `200`** are these cheap (they become plain GETs):
```bash
openfang status                 # provider, model, agent count  (prints "Data dir: ?" — known bug)
openfang doctor --json          # ignore its .env / "no API keys" false positives — see below
```

**Never gate on `doctor`'s exit code** — it exits **0** even when `all_ok` is **false**.

## Reference map

**Pull each in when you get there — do not load them all up front.** `gotchas.md` first when
something is surprising. **Where a reference and this router disagree, the reference wins** — except
on the launch command (#1), which is verbatim everywhere.

| File | When to read |
|---|---|
| `references/gotchas.md` | **ANY surprising behavior — check here before inventing a theory.** Cost-ordered: what kills the machine → what burns money → what burns hours → cosmetic. |
| `references/daemon-lifecycle.md` | start / stop / restart, the foreground + oomd traps, boot sequence, what's cached vs hot-reloaded, stale `daemon.json` |
| `references/agents.md` | **Priority.** `agent.toml` schema, workspace files (SOUL/IDENTITY/AGENTS/BOOTSTRAP/…), `[capabilities]` RBAC, creating an agent, the hardcoded GROQ/GEMINI fallback trap. Documents the `[model]` block's **fields**; the pinning **procedure** is Recipe C in `models-providers.md`. |
| `references/models-providers.md` | **Priority.** `[default_model]`, fallback chain + per-agent index math, `custom_models.json`, **Recipe A** = add a model · **Recipe B** = switch the GLOBAL default · **Recipe C** = pin one agent (sole owner), the parallel-tool-call incompatibility, inert budgets |
| `references/automation.md` | **Priority.** `[schedule]`, cron + fan-out delivery, triggers, workflows, hands, skills. Read before making an agent act on its own. |
| `references/memory-embeddings.md` | `[memory]`, the DB tables, the compactor, ollama embeddings, why old memories have no vectors |
| `references/config-reference.md` | Every `config.toml` key, `secrets.env` vs `.env`, all `OPENFANG_*` env vars, the comment-stripping and silent-defaults traps |
| `references/cli-reference.md` | All 40 commands + subcommands with exact signatures, which need the daemon, and DANGER tags |
| `references/api-mcp.md` | HTTP API routes + auth, the trailing-slash 404 trap, the 65 agent tools, mounting `openfang mcp` |
| `references/channels.md` | Telegram (in production here) and the other 43 adapters; the silent-bot triage; why WhatsApp is off-limits |
| `references/upstream-state.md` | Before saying "upgrade" / "file an issue" / "known bug". Abandoned upstream, the issue index, LibreFang |

### "Switch the model" — decide the SCOPE before you route

**"Switch the model" is ambiguous and the two answers live in different files. Resolve it out loud
with the user before editing anything.** Guessing "global" here changes the model for **all 30
agents including the live Telegram bot**.

| The ask | Scope | Go to |
|---|---|---|
| "use model X" / "switch to X" / "the default is bad" | **ALL 30 agents** | `models-providers.md` → Recipe B |
| **"make _agent Y_ use X"** / "just for the coder" / "only this bot" | **one agent** | `models-providers.md` → **Recipe C** (`agents.md` owns only the `[model]` *schema*) |
| "add X so it's available" | registry only, nothing switches | `models-providers.md` → Recipe A |

> **One owner for pinning: `models-providers.md` Recipe C.** It owns the procedure *and* the fallback
> math. `agents.md` documents the `[model]` block's fields and links here. If the two ever disagree
> again, Recipe C wins — earlier revisions had them giving opposite orders on `base_url`.

**Per-agent pinning traps — read Recipe C before improvising. Provenance marked; do not upgrade
these to certainty in your answer:**
- **Set BOTH `provider` and `model` to concrete values.** The inheritance check is
  `is_default_provider && is_default_model` — an **`&&`**. Setting `model` while leaving
  `provider = "default"` passes the literal `"default"` to the driver factory →
  `Unknown provider 'default'`. (UPSTREAM; not reproducible read-only.)
- **`pinned_model` is NOT the answer** despite the name — **not in the boot diff**, so setting it is
  silently ignored forever. It is the first thing you will reach for and it does nothing. (UPSTREAM.)
- **A pinned agent still falls back to the OLD model.** Index 0 is your new model. Config has
  **exactly 4** `[[fallback_providers]]` (VERIFIED: `grep -c '^\[\[fallback_providers\]\]'
  ~/.openfang/config.toml` → `4`) = kimi ×3 + llama. **But the chain length varies per agent** — 22 of
  30 ship their own `[[fallback_models]]`, which takes index 1 and pushes the globals to 2–5. Recipe C
  owns the index math; **do not recite a fixed range.** Either way one gonka 502 and the agent quietly
  answers on kimi while you believe it is on X — unfixable per-agent without moving everyone.
- **Delete the `api_key_env` line already in the block you are editing.** 11 of 30 `[model]` blocks
  ship one (8× GEMINI + 3× DEEPSEEK, VERIFIED) and none of those keys exist in `secrets.env`.
- **`base_url`: SUSPECT whether a pinned agent needs its own.** Unresolved read-only — but *harmless
  either way here*, since `[provider_urls]` already maps every alias to the same URL you would type.
  Recipe C rules: **set it**, because that does not depend on the unresolved question. Say you are unsure.
- **Precedent:** all **52/52** `provider =` lines read `"default"` (VERIFIED). Pinning is an
  **untrodden path on this box** — say so, and expect the TOML→DB diff to go quiet after (`agents.md`).

## This install

| | |
|---|---|
| Binary / home | `~/.openfang/bin/openfang` (66,306,848 B) · `~/.openfang/` |
| Daemon | `127.0.0.1:4200` · WebChat at `/` · **currently DOWN** (`health` → `000`) |
| ⚠️ Log location | **Depends on how it was launched.** `~/.openfang/daemon-start.log` is **frozen at the `2026-07-14T08:36:41Z` shutdown** (log lines are **UTC**; file mtime/journald are **local, +0200** — the same event reads `10:36:41` there. Two clocks, one event; never compare them raw). The sanctioned launch (#1) carries `-p StandardOutput="truncate:…"` **so this file keeps being written**. Drop that flag and the log moves to `journalctl --user -u openfang` and the file stays a fossil. **Before trusting any grep of it, confirm freshness** — `curl … /api/health` → `200`, or `stat -c %y`. Do not `tail` a stale file and conclude the boot hung *or succeeded*. |
| Default model | **`moonshotai/kimi-k2.6`** via `gonka-1` (`https://api.gonkagate.com/v1`) |
| Fallbacks | `gonka-2/3/4` (same model) → `nim-1` = `meta/llama-3.3-70b-instruct` (NVIDIA NIM) |
| ⚠️ Chain is **not** redundant | VERIFIED — all four gonka aliases resolve to **the same host** in `[provider_urls]`: `gonka-1..4 = https://api.gonkagate.com/v1`. They fail **as one**. The only true fallback is `nim-1`, which has itself returned `DEGRADED function cannot be invoked`. A single gonka outage takes out 4 of 5 entries. Report this; do not "fix" it unasked. |
| ⚠️ Model note | `minimaxai/minimax-m2.7` **breaks on parallel tool-calls** — that is why the default is kimi |
| Embeddings | ollama on `127.0.0.1:11434`, `mxbai-embed-large` (`[memory] embedding_provider = "ollama"`) |
| Channel | Telegram `@OpenAPIModelsBot`, gated to `allowed_users = ["83979215"]` |
| Agents | **30** dirs (all bundled templates auto-spawn at boot). Only **4** carry a `[schedule]` — re-VERIFIED (`grep -rl '^\[schedule\]' ~/.openfang/agents --include=agent.toml`): `ops` (`periodic = { cron = "every 5m" }`), `health-tracker` (`every 1h`), `orchestrator` (`continuous = { check_interval_secs = 120 }`), `security-auditor` (`proactive = { conditions = [...] }`). **`assistant` has NO schedule** (`grep -c schedule …/assistant/agent.toml` → **0**) — it holds `delivery.last_channel`, a different thing. Do not copy `assistant` as a "scheduled agent that posts to Telegram" template: it is neither. |
| "Agents look stuck" | **Red herring.** All 30 read `"suspended"` in the DB *with literal double quotes* (`state='"suspended"'` — plain `='suspended'` matches nothing). The column is a **spawn-time fossil, never written back**; it is not a status. Down daemon ⇒ nothing is running ⇒ nothing to unstick. → `gotchas.md` **G19** |
| ⚠️ Cost note | `agents/ops/agent.toml` ships `cron = "every 5m"` (upstream #1206) = 288 runs/day |
| Secrets | `~/.openfang/secrets.env` (**0600** ✓) · `config.toml` (0600 ✓) — **not** `.env`, which is why `doctor` cries wolf |
| 🔴 Token leak | **`daemon-start.log` is mode 0664 (world-readable) and contains the live bot token verbatim ×4** — the daemon prints the full `https://api.telegram.org/bot<TOKEN>/getUpdates` URL on every network error. VERIFIED (matched by count, never printed). **Every `grep … daemon-start.log` in this playbook can put the live token on your screen and into your transcript — pipe through a redactor.** The user knows and will rotate via @BotFather himself. **DOCUMENT, do not `chmod`.** |
| Auth | **No `[server]`/`[api]` section exists in `config.toml` at all** — VERIFIED, the only sections are `[channels.telegram] [default_model] [[fallback_providers]]×4 [memory] [provider_urls]`. So **no API key is configured** (VERIFIED) and the 127.0.0.1 bind + `localhost_only` are **compiled defaults, not configured values** — the string does not appear in `config.toml`. Safe *only* while that default holds; SUSPECT as a stated guarantee — settling it needs the binary or a live daemon. |

**Known false positives — do not "fix" them:** `doctor`'s `.env file not found` + `✘ No LLM provider
API keys found!` (it authenticates fine from `secrets.env`) · `status` printing `Data dir: ?` ·
`skill list` printing `No skills installed` (the 61 skills are compiled into the binary) ·
`models aliases`' broken table. All cosmetic. `doctor` is also **blind to custom providers and
`secrets.env`** — it cannot see a 502ing gonka, so it is **not** a pre-restart gate. Its
`channel -> warn` rows are of unknown benignity: UNVERIFIED. → `gotchas.md`, `daemon-lifecycle.md`

**Counts drift — every number here is an as-of-2026-07-14 snapshot, not an invariant.** The audit
total only ever grows (986 now, +9 per in-process kernel boot).
