# OpenFang automation — cron, schedules, triggers, workflows, hands, skills (v0.6.9)

**Read this when** the task involves anything an agent does *without a human prompt*: `[schedule]` in
`agent.toml`, `openfang cron` / `/api/cron/jobs`, `openfang trigger`, `openfang workflow`,
`openfang hand`, `openfang skill`, the `schedule_*` / `cron_*` agent tools, delivering scheduled
output to Telegram/webhook/file/email, or diagnosing "why is this agent burning tokens on its own".

Evidence tags: **VERIFIED** = observed on this install (command + real output shown) ·
**UPSTREAM** = read from `RightNow-AI/openfang@v0.6.9` source/docs (file:line cited) ·
**SUSPECT** = contradictory evidence, settling test given · **UNVERIFIED** = could not test, reason given.

Upstream is **abandoned** (last `main` commit 2026-05-12 = v0.6.9 = installed). No fix is coming for
anything below. Every bug here is permanent — design around it.

---

## The six things that waste the most time (read first)

0. **`[schedule]` in `agent.toml` HAS NO DELIVERY. If the scheduled result must be sent anywhere,
   you need a cron job, not `[schedule]`.** The two are unrelated code paths sharing one word.
   "Run every 30 min and post to Telegram" written as `[schedule] periodic` is a silent no-op that
   still costs tokens on every tick. **Never set both** — two timers, double spend, one delivers.
   → [Recipe: scheduled agent that posts to Telegram](#recipe-scheduled-agent-that-posts-to-telegram-the-canonical-task).

1. **There are THREE mutually incompatible schedule dialects.** A string that works in one is
   silently wrong or rejected in the others. `every 5m` works ONLY in `agent.toml`. `every 5 minutes`
   works ONLY in the `schedule_create` tool. `0 */6 * * *` works ONLY in cron/API — and in
   `agent.toml` it **silently becomes 300 seconds**. See [The three dialects](#the-three-dialects).

2. **`openfang cron create` prints `Failed: ?` when it SUCCEEDS.** The CLI reads `body["id"]`; the API
   returns `{"result":"{\"job_id\":...,\"status\":\"created\"}"}`. The key never matches, so the CLI
   always reports failure — while the job is created and persisted. **Do not retry — you will create
   duplicate jobs.** UPSTREAM `openfang-cli/src/main.rs:6120` vs `openfang-api/src/routes.rs:11349`.
   **Use the HTTP API directly for all cron writes.**

3. **`openfang cron create <AGENT>` requires a UUID**, despite the arg help saying `Agent name or ID
   to run`. The CLI forwards the string verbatim; the kernel does `uuid::Uuid::parse_str(agent_id)`.
   A name yields `Failed: Invalid agent ID: invalid length: expected length 32 for simple format,
   found 3`. (The `schedule_create` *tool* resolves names; the CLI does not.)
   UPSTREAM `openfang-kernel/src/kernel.rs:7406`.

4. **`delivery: last_channel` silently delivers nothing unless that exact agent has already sent a
   successful outbound channel message.** The `delivery.last_channel` kv key is written only by the
   channel bridge on outbound success — never by the cron path itself. When the key is missing, the
   job logs `Cron: no last channel found for agent <uuid>` and **records SUCCESS**. On this install
   only `assistant` has the key. See [last_channel](#delivery-last_channel--the-undocumented-reply-path).

5. **The autonomous loops are a token furnace, and cost accounting reports $0.00.** Live on this box:
   **117.8 input tokens per output token**, 535,106 input vs 4,543 output across 64 calls in ~12.6 h,
   ~86% of it from `orchestrator` alone concluding "No actionable items". See [Cost model](#cost-model--what-the-schedules-actually-burn).

---

## Subsystem map — five separate mechanisms, one word ("schedule")

| Mechanism | Defined in | Survives restart? | Schedule parser | Fired by |
|---|---|---|---|---|
| `[schedule] periodic` | `agents/<n>/agent.toml` | yes (file) | `parse_cron_to_secs` — `every N{s,m,h,d}` **only** | `background.rs` timer |
| `[schedule] continuous` | `agent.toml` | yes (file) | `check_interval_secs` (raw u64) | `background.rs` timer |
| `[schedule] proactive` | `agent.toml` | yes (file) | `parse_condition` → auto-registers triggers | trigger engine |
| Cron jobs | `~/.openfang/cron_jobs.json` | **yes** | `validate_cron_expr` — 5-field cron / `every_secs` / `at` | `cron.rs` 15 s tick |
| Triggers | **memory only** | **NO** | n/a (event patterns) | event bus |
| Workflows | `~/.openfang/workflows/<uuid>.json` | yes (file) — **delete does not remove the file** | n/a | manual / cron `workflow_run` |

**The trap in this table:** `[schedule]` and the cron subsystem are *unrelated code paths* that share
vocabulary. `[schedule] periodic = { cron = "..." }` never touches `cron_jobs.json`, never appears in
`openfang cron list`, has no delivery, no `max_fires`, no per-job enable/disable, and cannot be
stopped without editing `agent.toml` and restarting the daemon.

**VERIFIED — live state on this install:**
```bash
cat /home/kyzdes/.openfang/cron_jobs.json
# []
grep -rl "^\[schedule\]" /home/kyzdes/.openfang/agents --include="agent.toml" | head -20
# /home/kyzdes/.openfang/agents/ops/agent.toml
# /home/kyzdes/.openfang/agents/security-auditor/agent.toml
# /home/kyzdes/.openfang/agents/health-tracker/agent.toml
# /home/kyzdes/.openfang/agents/orchestrator/agent.toml
```
Zero cron jobs. Four scheduled agents. All autonomy on this box comes from `agent.toml`, not cron.

---

## The three dialects

This is the single highest-value fact in this document. **Verify which parser you are feeding before
writing any schedule string.**

### Dialect 1 — `agent.toml` `[schedule] periodic.cron` → `parse_cron_to_secs`

UPSTREAM `openfang-kernel/src/background.rs:210-250`. Accepts **only** `every <N><unit>` where unit is
one of `s`, `m`, `h`, `d`. **Everything else falls through to 300 seconds with a warning.**

```rust
// background.rs — the whole grammar
if let Some(rest) = cron.strip_prefix("every ") {
    if let Some(n) = rest.strip_suffix('s') { return n; }        // every 30s → 30
    if let Some(n) = rest.strip_suffix('m') { return n * 60; }   // every 5m  → 300
    if let Some(n) = rest.strip_suffix('h') { return n * 3600; } // every 1h  → 3600
    if let Some(n) = rest.strip_suffix('d') { return n * 86400; }
}
warn!(cron = %cron, "Unparseable cron expression, defaulting to 300s");
300
```

Upstream's own tests spell out the trap (`background.rs`, `test_parse_cron_fallback`):
```rust
assert_eq!(parse_cron_to_secs("*/5 * * * *"), 300);
assert_eq!(parse_cron_to_secs("gibberish"), 300);
```

**Consequences — bold, because these silently cost money:**

- **`cron = "0 9 * * *"` in `agent.toml` does NOT mean 9 a.m. It means every 300 seconds — 288 runs
  per day instead of 1.** A 288× cost overrun that produces no error.
- **`cron = "every 2 hours"` → 300 s, not 7200 s.** `strip_suffix('s')` fires first on the trailing
  `s` of "hours", leaves `"2 hour"`, `parse::<u64>` fails, and every other suffix misses. A 24×
  overrun. Same for `"every 5 minutes"`, `"every 30 seconds"` — any *plural English* form.
- **`cron = "every 1s"` is accepted and starts a 1-second self-prompt loop.** There is no minimum
  here (the cron subsystem enforces `MIN_EVERY_SECS = 60`; `agent.toml` enforces nothing).
- The fallback log line is `WARN openfang_kernel::background: Unparseable cron expression,
  defaulting to 300s`. **Grep for it after every `agent.toml` edit** — it is the only signal.

**VERIFIED — this install parses correctly, but only because both values are in the legal grammar:**
```bash
grep -E "background loop" /home/kyzdes/.openfang/daemon-start.log | sed -e 's/\x1b\[[0-9;]*m//g' | head -8
# ...INFO openfang_kernel::background: Starting periodic background loop agent=ops
#     id=cbbfb77e-14f4-4c44-8c1a-7260986900c9 cron=every 5m interval_secs=300
# ...INFO openfang_kernel::background: Starting continuous background loop agent=orchestrator
#     id=91c689c2-17e3-4763-b360-65aea020cc57 interval_secs=120
# ...INFO openfang_kernel::background: Starting periodic background loop agent=health-tracker
#     id=c08fae4f-6c67-4733-a6ea-3610bdeecde0 cron=every 1h interval_secs=3600
```
`grep -c "Unparseable cron" daemon-start.log` → `0`. **The `interval_secs=` field in that log line is
ground truth — always read it back rather than trusting the string you wrote.**

### Dialect 2 — the `schedule_create` agent tool → `parse_schedule_to_cron`

UPSTREAM `openfang-runtime/src/tool_runner.rs` (`parse_schedule_to_cron`). This is a **natural-language
→ 5-field-cron** compiler that then hands off to the real cron subsystem. Accepts:

| Input | → cron |
|---|---|
| 5 fields of `0-9 * / , -` | passed through verbatim |
| `every minute` / `every 1 minute` | `* * * * *` |
| `every N minutes` (N = 1–59) | `*/N * * * *` |
| `every hour` / `every 1 hour` | `0 * * * *` |
| `every N hours` (N = 1–23) | `0 */N * * *` |
| `every day` / `daily` | `0 0 * * *` |
| `every week` / `weekly` | `0 0 * * 0` |
| `hourly` | `0 * * * *` |
| `monthly` | `0 0 1 * *` |
| `daily at 9am` | `0 9 * * *` |
| `weekdays at 6pm` | `0 18 * * 1-5` |
| `weekends at 8am` | `0 8 * * 0,6` |

Verbatim errors (greppable): `Minutes must be 1-59, got 60` · `Hours must be 1-23, got 24` ·
`Invalid number in 'every x minutes'` · `Could not parse schedule 'every 5m'. Try: 'every 5 minutes',
'daily at 9am', 'weekdays at 6pm', or a cron expression like '0 */5 * * *'`.

**`every 5m` — the exact string in `ops/agent.toml` — is an ERROR here.** The two dialects are
inverses of each other: `agent.toml` accepts only `every 5m` and rejects `every 5 minutes`;
`schedule_create` accepts only `every 5 minutes` and rejects `every 5m`.

`schedule_create` params: `description` (required, also becomes the job name AND the agent-turn
message), `schedule` (required), `agent` (optional; `""`/`"self"` → caller, UUID passed through, name
resolved via `find_agents` — exact match wins, single fuzzy match accepted, ambiguity errors with
`Agent name 'x' is ambiguous (N matches). Pass the agent UUID.`).
**`schedule_create` hardcodes `"delivery": {"kind":"none"}` and `"one_shot": false`** — output goes
nowhere but the WebSocket. To get delivery you must use `cron_create` or the HTTP API.

### Dialect 3 — cron subsystem (`openfang cron`, `/api/cron/jobs`, `cron_create` tool) → `validate_cron_expr`

UPSTREAM `openfang-types/src/scheduler.rs:427`. **Exactly 5 fields**, and each field may contain only
`0-9 * / - , ?`.

```
cron expression must have exactly 5 fields (got 2): "every 5m"
cron field 4 contains invalid characters: "MON"
cron expression must not be empty
```

**Letters are rejected.** `MON`, `JAN`, `@daily`, `@hourly` all fail. Field order is
`min hour dom month dow`. At fire time it is widened to the `cron` crate's 7-field form
(`format!("0 {trimmed} *")` — seconds `0`, year `*`), so **6-field input silently means
`sec min hour dom month dow`**, not the 5-field layout. Timezone comes from the separate `tz` field
(`chrono_tz` name); an invalid tz logs `Invalid timezone 'X' in cron job, falling back to UTC`.
`tz` is honoured for DST. UPSTREAM `openfang-kernel/src/cron.rs:444-500`.

📌 **`tz` is a FILL-ME field — substitute your host's zone; do not copy the examples blind.**
**This host is `Europe/Warsaw`** (VERIFIED: `timedatectl show -p Timezone --value`), which is what
the examples below now use. Earlier revisions hardcoded `Europe/Berlin` in five places — harmless
here *only by luck* (Berlin and Warsaw share CET/CEST), and irrelevant to `*/30` specifically, but it
would silently shift every `0 9 * * *` example on any other box. Check yours.

---

## The cron subsystem

### Storage and lifecycle

- File: `~/.openfang/cron_jobs.json` — a JSON **array of `JobMeta`**, not of `CronJob`:
  `[{"job":{...CronJob...},"one_shot":false,"last_status":"ok","consecutive_errors":0}, ...]`.
  Atomic write (`.json.tmp` → rename). UPSTREAM `cron.rs:110-140`.
- Loaded once at boot: `INFO openfang_kernel::cron: Loaded cron jobs from disk count=0` (VERIFIED,
  this install). **Editing `cron_jobs.json` while the daemon runs is pointless and unsafe** — the
  in-memory `DashMap` is authoritative and overwrites the file every ~5 minutes and on shutdown.
  For editing it while **stopped**, see [Authoring cron jobs offline](#authoring-cron-jobs-offline-daemon-down).
- Tick interval **15 s**, `MissedTickBehavior::Skip`. UPSTREAM `kernel.rs:4661`.
- **Due jobs in one tick run SERIALLY** (`for job in due { kernel.cron_run_job(&job).await }`,
  `kernel.rs:4674`). One slow job delays every other job in that tick. Combined with #1230 (an agent
  processes requests serially), two jobs on the same agent will queue.
- Persist cadence: every 20 ticks (~5 min) and on shutdown. **A crash within 5 minutes of a change
  loses `last_run` / `consecutive_errors` / `enabled`** — but not the job itself if it was created
  through the API (create persists immediately, `kernel.rs:7429`).
- Caps: `MAX_JOBS_PER_AGENT = 50` (hard-coded); global cap from root config `max_cron_jobs`
  (validator rejects `> 10000`: `max_cron_jobs exceeds reasonable limit (10000)`).
  Errors: `agent already has 50 jobs (max 50)` · `Global cron job limit reached (N)`.
- **Auto-disable after 5 consecutive failures** (`MAX_CONSECUTIVE_ERRORS = 5`), logged
  `WARN openfang_kernel::cron: Auto-disabling cron job after repeated failures`. The job stays in the
  file with `"enabled": false`. **Nothing re-enables it** — a 25-minute channel outage on an
  `every_secs: 300` job permanently kills it.

### Authoring cron jobs offline (daemon down)

**Answer first: for a NEW agent, you cannot. Booting the daemon is unavoidable — plan for it.**

A cron job addresses its agent by **UUID**, and a UUID only exists once the kernel has registered
the agent. An `agents/<name>/agent.toml` you just wrote has no UUID anywhere: the kernel mints one
at boot when it auto-spawns dirs present on disk but **`not in registry`** (binary strings
`auto-spawn agent from disk` / `Auto-spawned agent from disk` / `not in registry`, VERIFIED below).
So the sequence for a new agent is always **write manifest → start daemon (UUID is minted) →
POST the cron job** — and by step 3 the daemon is up, which makes the offline path moot.

Offline editing is only meaningful for an **agent that already exists in the DB**. Its UUID is
readable without the daemon — this is the substitute for `curl $B/api/agents`:

**VERIFIED (daemon down, `curl … /api/health` → `000`):**
```bash
sqlite3 /home/kyzdes/.openfang/data/openfang.db \
  "SELECT id,name FROM agents WHERE name='ops' LIMIT 1;"
# cbbfb77e-14f4-4c44-8c1a-7260986900c9|ops
```
(Cross-checks against the `id=cbbfb77e-…` in the `Starting periodic background loop agent=ops` boot
log line quoted under [The three dialects](#the-three-dialects).)

#### The on-disk shape — and how it differs from the POST body

**They are not the same object. `one_shot` is top-level in the POST body but lives in the `JobMeta`
wrapper on disk, NOT inside `job`.** The kernel also mints five fields the POST body must not carry.

```jsonc
// ~/.openfang/cron_jobs.json — array of JobMeta
[{
  "job": {                       // ← CronJob
    "id":               "<uuid>",        // ← kernel-minted; NOT in the POST body
    "agent_id":         "<uuid>",
    "name":             "reporter-30m",
    "schedule":         {"kind":"cron","expr":"*/30 * * * *","tz":"Europe/Warsaw"},
    "action":           {"kind":"agent_turn","message":"…","timeout_secs":300},
    "delivery":         {"kind":"none"},
    "delivery_targets": [{"type":"channel","channel_type":"telegram","recipient":"83979215"}],
    "enabled":          true,            // ← kernel-minted; NOT in the POST body
    "next_run":         "<rfc3339>",     // ← kernel-minted; NOT in the POST body
    "last_run":         null,            // ← kernel-minted; NOT in the POST body
    "created_at":       "<rfc3339>"      // ← kernel-minted; NOT in the POST body
  },
  "one_shot":           false,   // ← JobMeta, NOT job. Top-level in the POST body.
  "last_status":        "ok",    // ← JobMeta
  "consecutive_errors": 0        // ← JobMeta
}]
```

**VERIFIED — the `CronJob` field list is read out of the binary's own bundled dashboard, which
normalizes the live `/api/cron/jobs` response field by field:**
```bash
strings -n 4 /home/kyzdes/.openfang/bin/openfang | grep -nE "j\.[a-z_]+" | head -40
# 32487:          id: j.id,
# 32488:          name: j.name,
# 32490:          agent_id: j.agent_id,
# 32491:          message: j.action ? j.action.message || '' : '',
# 32492:          enabled: j.enabled,
# 32493:          last_run: j.last_run,
# 32494:          next_run: j.next_run,
# 32495:          delivery: j.delivery ? j.delivery.kind || '' : '',
# 32496:          delivery_targets: Array.isArray(j.delivery_targets) ? j.delivery_targets : [],
# 32497:          created_at: j.created_at
```
`JobMeta`'s three wrapper fields are confirmed adjacent to the persist site:
```bash
strings -n 8 /home/kyzdes/.openfang/bin/openfang | grep -F "consecutive_errors" | head -1
# …crates/openfang-kernel/src/cron.rs:137Persisted cron jobslast_statusconsecutive_errors…
```
Note `one_shot` is **absent** from the dashboard's `j.*` list — consistent with it living in
`JobMeta`, not `CronJob`.

#### The stop → edit → start procedure

**UNVERIFIED — not executed: the daemon is down on this install and starting it is out of scope.
The schema above is read from the binary, not from a round-tripped file.** The unknown is serde
strictness: whether the kernel-minted fields (`id`, `enabled`, `next_run`, `last_run`,
`created_at`) carry `#[serde(default)]` or are **required on deserialize**. If they are required,
omitting any one of them fails the whole file.

**The failure mode is a silent total wipe, which is why this is the last resort.** `Failed to parse
cron jobs:` exists as a string in the binary (alongside `Failed to load cron jobs:` /
`Failed to read cron jobs:`); the file is parsed as **one array**, so a single malformed entry
takes out *every* job in the file, and the next persist tick (~5 min) writes the now-empty in-memory
map back over your edit.

```bash
openfang stop                                        # MUTATING — needs explicit user approval
cp /home/kyzdes/.openfang/cron_jobs.json /home/kyzdes/.openfang/cron_jobs.json.bak   # always
# edit cron_jobs.json — full JobMeta, every field above, id = a fresh uuidgen
python3 -m json.tool /home/kyzdes/.openfang/cron_jobs.json >/dev/null && echo "json ok"
openfang start                                       # MUTATING — see daemon-lifecycle.md
```
**Verification is mandatory and the count is the whole test:**
```bash
grep -E "Loaded cron jobs from disk|Failed to (parse|load|read) cron jobs" \
  /home/kyzdes/.openfang/daemon-start.log | sed -e 's/\x1b\[[0-9;]*m//g' | tail -5
# count=N must equal the number of entries you wrote. count=0 → your file did not parse.
```
**If `count` is short, stop and restore the backup before the ~5-minute persist tick overwrites it.**

**Recommendation: don't. Use `POST /api/cron/jobs` against a live daemon.** That path validates the
body, mints the five fields correctly, and persists immediately (`kernel.rs:7429`) — and since a new
agent forces a daemon start anyway, the offline route buys nothing but risk.

### The JSON contract

UPSTREAM `openfang-types/src/scheduler.rs`. All three enums are **internally tagged** — but note the
tag key differs between `CronDelivery`/`CronSchedule`/`CronAction` (`"kind"`) and
`CronDeliveryTarget` (**`"type"`**). Getting this wrong yields `Invalid delivery_targets: ...`.

```jsonc
{
  "agent_id": "<UUID — never a name>",
  "name": "daily-report",              // 1..128 chars; alphanumeric + space - _ only
  "schedule": { "kind": "cron",  "expr": "0 9 * * *", "tz": "Europe/Warsaw" },
  //           { "kind": "every", "every_secs": 300 }        // 60 ≤ n ≤ 86400
  //           { "kind": "at",    "at": "2026-08-01T09:00:00Z" }  // future, ≤ ~1 year
  "action":   { "kind": "agent_turn", "message": "...", "model_override": null, "timeout_secs": 300 },
  //           { "kind": "system_event", "text": "..." }                    // text ≤ 4096
  //           { "kind": "workflow_run", "workflow_id": "<uuid or name>", "input": "...", "timeout_secs": 300 }
  "delivery": { "kind": "last_channel" },                    // legacy single target
  //           { "kind": "channel", "channel": "telegram", "to": "83979215" }
  //           { "kind": "webhook", "url": "https://..." } | { "kind": "none" }
  "delivery_targets": [                                      // NEW multi-target fan-out; tag is "type"
    { "type": "channel",    "channel_type": "telegram", "recipient": "83979215" },
    { "type": "webhook",    "url": "https://hook", "auth_header": "Bearer x" },
    { "type": "local_file", "path": "/tmp/out.md", "append": true },
    { "type": "email",      "to": "a@b.c", "subject_template": "Cron: {job}" }
  ],
  "one_shot": false
}
```

Validation limits (verbatim error text in parentheses):
`every_secs` 60–86400 (`every_secs too small (30, min 60)`) · `at` must be future and ≤ 365 d
(`scheduled time must be in the future`) · `timeout_secs` 10–600 (`timeout_secs too large (900, max
600)`) · `message` ≤ 16384 (`agent turn message too long`) · name charset
(`name may only contain alphanumeric characters, spaces, hyphens, and underscores`).

**`delivery` and `delivery_targets` are independent and both fire.** `delivery_targets` fan out first
via `futures::future::join_all` and **never fail the job**; then legacy `delivery` runs and **its
failure marks the job failed** (`record_failure(job_id, "channel delivery failed")` →
counts toward the 5-strike auto-disable). UPSTREAM `kernel.rs:6607-6650`.
**Practical rule: put real destinations in `delivery_targets` and set `delivery` to `{"kind":"none"}`,
unless you specifically want delivery failure to disable the job.**

**Both are omittable** — `cron_create` defaults `delivery` to `None` and `delivery_targets` to `[]`
when the keys are absent or the wrong JSON type. A **typo in the key name silently disables delivery**
rather than erroring (`if job_json["delivery"].is_object()`, `kernel.rs:7392`).

**`{"kind":"at"}` with `one_shot: false` fires forever at the tick rate.** `compute_next_run_after`
returns `at` unchanged for the `At` variant, so `next_run` stays in the past and the job re-fires
every 15 s. Only `one_shot: true` removes it (`record_success` → `if meta.one_shot { remove }`).
UPSTREAM `cron.rs:446` + `cron.rs:~370`. **Always pair `at` with `one_shot: true`.**
UNVERIFIED at runtime — daemon is down; this is read from source.

### The CLI is broken for cron — use HTTP

Every claim below is UPSTREAM, from comparing `openfang-cli/src/main.rs` against
`openfang-api/src/{server,routes}.rs@v0.6.9`.

| Command | What it does | Reality |
|---|---|---|
| `cron list` | `GET /api/cron/jobs`, then `body.as_array()` | API returns **`{"jobs":[...],"total":N}`** → `as_array()` is `None` → **the table never renders**; it dumps raw JSON and never prints `No scheduled jobs.` Also reads `j["cron_expr"]`/`j["prompt"]`, which `CronJob` never serializes (`schedule`/`action`). Same bug class as `models aliases`. |
| `cron create` | `POST /api/cron/jobs`, reads `body["id"]` | API returns `{"result":"{\"job_id\":…}"}` (201) → **always prints `Failed: ?` on success**. Also always sends `{"kind":"cron","expr":SPEC}` → **`every`/`at` schedules are unreachable from the CLI**, and no delivery is ever set. Also forwards the agent NAME as `agent_id` → 400. |
| `cron enable` | `POST /api/cron/jobs/{id}/enable` | Route is **`PUT`** and requires body `{"enabled":true}` → **405**. |
| `cron disable` | `POST /api/cron/jobs/{id}/disable` | **No such route exists** → **404**. Disable is `PUT .../enable` with `{"enabled":false}`. |
| `cron delete` | `DELETE /api/cron/jobs/{id}` | **works.** |

By contrast `workflow list` and `trigger list` are fine — `/api/workflows` and `/api/triggers` return
bare arrays.

**VERIFIED — with the daemon down every one of these fails identically:**
```bash
/home/kyzdes/.openfang/bin/openfang cron list
#   ✘ `openfang cron list` requires a running daemon
#     fix: Start the daemon: openfang start
#   hint: Or try `openfang chat` which works without a daemon
```

**The supported path — HTTP.** Auth on this install: `{"auth":{"api_key_set":false,"mode":"localhost_only"}}`,
so loopback needs no token. **Do not use trailing slashes** — `/api/cron/jobs/` 404s while
`/api/cron/jobs` 200s.

```bash
B=http://127.0.0.1:4200
AID=$(curl -sS $B/api/agents | jq -r '.[]|select(.name=="ops").id')   # UUID is mandatory

# READ (safe)
curl -sS $B/api/cron/jobs | jq '.total, .jobs[]|{id,name,enabled,next_run,schedule}'
curl -sS "$B/api/cron/jobs?agent_id=$AID" | jq .
curl -sS $B/api/cron/jobs/<JOB_ID>/status | jq .

# WRITE (mutating — needs explicit user approval)
curl -sS -X POST $B/api/cron/jobs -H 'Content-Type: application/json' -d "{
  \"agent_id\":\"$AID\", \"name\":\"daily-digest\",
  \"schedule\":{\"kind\":\"cron\",\"expr\":\"0 9 * * *\",\"tz\":\"Europe/Warsaw\"},
  \"action\":{\"kind\":\"agent_turn\",\"message\":\"Summarise overnight alerts.\",\"timeout_secs\":300},
  \"delivery\":{\"kind\":\"none\"},
  \"delivery_targets\":[{\"type\":\"channel\",\"channel_type\":\"telegram\",\"recipient\":\"83979215\"}],
  \"one_shot\":false}"
# → 201 {"result":"{\"job_id\":\"…\",\"status\":\"created\"}"}   ← note: result is a JSON STRING
curl -sS -X PUT $B/api/cron/jobs/<ID>/enable -H 'Content-Type: application/json' -d '{"enabled":false}'
curl -sS -X POST $B/api/cron/jobs/<ID>/run     # on-demand fire; does not disturb next_run unless overdue
curl -sS -X DELETE $B/api/cron/jobs/<ID>
```

`"result"` is **double-encoded** (`serde_json::json!({...}).to_string()`): its *value* is a JSON
string containing JSON. **`fromjson` it exactly ONCE** — `jq -r '.result | fromjson | .job_id'`.
("Double-encoded" describes the data, not the number of `fromjson` calls; a second one gives you
`Cannot iterate over string`.) Same disease as `memories.source` and `agents.state`.

On-demand run errors: `Schedule not found` · `Schedule is disabled` · `Invalid schedule id` ·
`On-demand cron job completed` / `On-demand cron job failed`.

### Delivery fan-out

UPSTREAM `openfang-kernel/src/cron_delivery.rs`. All `delivery_targets` are attempted concurrently
(`join_all`); one failure never blocks the others; each returns
`DeliveryResult { target, success, error }`. Log lines (all at DEBUG for success, WARN for failure —
**successes are invisible at the default `log_level`**):

```
Cron fan-out: channel delivery ok | failed        target=channel:telegram -> 83979215
Cron fan-out: webhook delivery ok | failed        target=webhook:https://…
Cron fan-out: file write ok | failed              target=file:/tmp/out.md
Cron fan-out: email delivery ok | failed          target=email:a@b.c
```

- **webhook** — `POST` with 30 s timeout, body `{"job":<name>,"output":<text>,"timestamp":<rfc3339>}`,
  `auth_header` sent verbatim as `Authorization`.
- **local_file** — `append: false` (the default) **truncates the file every run**.
- **email** — routed through the `email` channel adapter as `"{subject}\n\n{output}"`; there is no
  real subject header. `subject_template` supports exactly one placeholder, **`{job}`** (single
  braces, *not* `{{job}}`); default `Cron: <name>`.
- **channel** — `channel_type` must match a **configured** adapter. `channel list` shows 8 of 44
  compiled-in channels; `/api/channels` is the truth.

#### Does fan-out respect the agent's `[capabilities]`?

**Almost certainly NO — cron delivery is a kernel path and is not gated by agent RBAC. Do NOT add
`channel_send` to `[capabilities] tools` on account of a cron job. UNVERIFIED at runtime: the
daemon is down and this needs a live fire to settle.**

Static evidence, both **VERIFIED** against the installed binary:
```bash
B=/home/kyzdes/.openfang/bin/openfang
strings -n 8 $B | grep -F "Capability denied: tool not in allowed list" | head -1 | cut -c1-260
# …Perplexity API key not sethttps://api.perplexity.ai/chat/completionscitationsperplexity-search
#   Capability denied: tool not in allowed listApproval bypassed: exec_policy grants unrestricted
#   shell accessApproval denied
```
The capability check's error string is interned **inside the runtime tool-dispatch blob** — its
neighbours are tool implementations (`perplexity-search`) and the approval gate
(`Approval bypassed` / `Approval denied`). It is a *tool-call* guard.

```bash
strings -n 4 $B | grep -oE "Cron: deliver[a-z ]{0,25}|Cron fan-out[^\"]{0,30}" | sort -u | head
# Cron fan-out: channel delivery ok
# Cron fan-out: email delivery ok
# Cron fan-out: file write ok
# Cron fan-out: partial delivery
# Cron fan-out: webhook delivery ok
# Cron: delivering to channel
# Cron: delivering via webhook
```
The delivery path (`cron_delivery.rs`, `kernel.rs:7006-7068`, `kernel.rs:7141-7155`) has **no
capability or approval string anywhere near it**. It runs *after* the agent turn returns, against
the `CronJob`'s own `delivery`/`delivery_targets` — there is no tool call and no agent tool context
to check against.

**Why this matters:** if you guess wrong the other way and *omit* `channel_send` believing delivery
needs it, nothing breaks. If you guess wrong and *add* `channel_send`, you have handed a scheduled,
unattended agent the ability to message your Telegram on its own initiative. **Omit it.**

**Settling test** (needs the daemon up — not run here). Create a job on an agent whose
`[capabilities] tools` does **not** list `channel_send`, with a `delivery_targets` telegram entry,
then fire it on demand and read the logs at `debug`:
```bash
curl -sS -X POST http://127.0.0.1:4200/api/cron/jobs/<JOB_ID>/run
grep -E "Cron fan-out: channel delivery|Capability denied" /home/kyzdes/.openfang/daemon-start.log | tail -5
# "Cron fan-out: channel delivery ok"  → NOT capability-gated (expected)
# "Capability denied"                  → it IS gated; add channel_send
```
The **only** trustworthy confirmation is the message arriving on the phone — see
[the verification checklist](#recipe-scheduled-agent-that-posts-to-telegram-the-canonical-task).
Note the separate, real case: a **`[schedule]`** agent asked to post to Telegram calls the
`channel_send` **tool**, which *is* on the RBAC path and *does* need `channel_send` in
`[capabilities] tools`. Do not carry that requirement over to cron.

### `delivery.last_channel` — the undocumented reply path

`{"kind":"last_channel"}` reads kv `delivery.last_channel` for **that agent** and sends there.

**VERIFIED:**
```bash
sqlite3 /home/kyzdes/.openfang/data/openfang.db \
  "SELECT agent_id,key,substr(value,1,120) FROM kv_store LIMIT 10;"
# 00000000-0000-0000-0000-000000000001|__openfang_schedules_migrated_v1|true
# b09ea7eb-fb30-442f-934c-1a4049cdec16|delivery.last_channel|{"channel":"telegram","recipient":"83979215"}
sqlite3 /home/kyzdes/.openfang/data/openfang.db "SELECT name FROM agents WHERE id LIKE 'b09ea%';"
# assistant
```
**Exactly one of 30 agents has the key.** A `last_channel` job on any other agent delivers nothing.

**Who writes it:** `openfang-api/src/channel_bridge.rs:886-895` — on **every successful outbound
channel message**, including `thread_id` when present. **Who else:** `kernel.rs:7011` — the
`CronDelivery::Channel` path writes it as a side effect. **`CronDelivery::LastChannel` never writes
it**, so it cannot bootstrap itself.

**Two traps:**

1. **Missing key = silent success.** `kernel.rs:7047`: `_ => { tracing::debug!("Cron: no last channel
   found for agent {}", agent_id); Ok(()) }`. Returns `Ok` → `delivered_to_channel = true` →
   `record_success`. The job's `last_status` reads `"ok"` while nothing was ever sent.
   **`last_status: "ok"` does not mean delivered.**
2. **`thread_id` is persisted but dropped on read.** The writer stores `thread_id`; the reader
   (`kernel.rs:7027`) extracts only `channel`/`recipient` and calls
   `send_channel_message(channel, recipient, response, None)`. **Scheduled replies to a Telegram
   forum topic land in General, not the topic.**

**To bootstrap `last_channel` for an agent: have it send one successful message on the target channel
first** (any inbound-then-reply exchange, or a `channel_send` tool call). Then verify:
```bash
sqlite3 /home/kyzdes/.openfang/data/openfang.db \
  "SELECT key,value FROM kv_store WHERE key='delivery.last_channel' LIMIT 5;"
```
Prefer an explicit `delivery_targets` entry with a literal `recipient` — it has none of these failure
modes.

### Legacy `__openfang_schedules` migration

VERIFIED: kv `00000000-…-0001 | __openfang_schedules_migrated_v1 | true`. One-shot, idempotent, runs
at boot on the sentinel agent; converts pre-0.6 shared-memory schedule entries into cron jobs
(`Migrated legacy __openfang_schedules entries to cron scheduler`, skips bad rows with
`Schedule migration: skipping legacy entry` / `missing 'cron' field` / `empty cron expression` /
`no target agent specified`, names them `migrated-schedule`). Already complete here with nothing to
migrate. Ignore unless restoring an ancient install.

---

## `[schedule]` in `agent.toml`

```toml
[schedule]
periodic   = { cron = "every 5m" }                                        # timer, every N{s,m,h,d}
continuous = { check_interval_secs = 120 }                                # timer, raw seconds
proactive  = { conditions = ["event:agent_spawned", "event:agent_terminated"] }  # event-driven
# absent  = Reactive — the default; agent only acts when messaged
```

> **`[schedule]` HAS NO DELIVERY. If the result must be sent anywhere — Telegram, webhook, file,
> email — `[schedule]` cannot do it. Use the [cron subsystem](#the-cron-subsystem) instead.**
> A `[schedule]` response goes to the agent's session and the WebSocket and nowhere else: there is
> no `delivery` field in the `[schedule]` grammar and no code path from `background.rs` to
> `cron_delivery.rs`. An agent with `periodic = { cron = "every 30m" }` and a "post this to
> Telegram" system prompt will burn tokens every 30 minutes and post nothing — **unless the prompt
> makes the model call the `channel_send` tool itself, which is a request, not a guarantee.**
> The canonical fix is [Recipe: scheduled agent that posts to Telegram](#recipe-scheduled-agent-that-posts-to-telegram-the-canonical-task).
>
> **Do not set `[schedule]` *and* a cron job on the same agent as belt-and-braces.** They are
> independent timers (see the [Subsystem map](#subsystem-map--five-separate-mechanisms-one-word-schedule));
> you get two runs per interval at double the token spend, and only one of them delivers.
> **Pick exactly one.**

**VERIFIED — the exact live blocks:**
```bash
for f in ops security-auditor health-tracker orchestrator; do echo "== $f"; \
  grep -A2 "^\[schedule\]" /home/kyzdes/.openfang/agents/$f/agent.toml; done
# == ops               → periodic   = { cron = "every 5m" }
# == security-auditor  → proactive  = { conditions = ["event:agent_spawned", "event:agent_terminated"] }
# == health-tracker    → periodic   = { cron = "every 1h" }
# == orchestrator      → continuous = { check_interval_secs = 120 }
```
`assistant` has **no** `[schedule]` — only `[autonomous] max_iterations = 100`, which is the
tool-loop cap per turn, **not** a schedule. (This corrects the seed: 4 scheduled agents, not 5.)

### Semantics (UPSTREAM `background.rs:34-170`)

- **Continuous** sleeps `check_interval_secs`, then self-prompts verbatim:
  `[AUTONOMOUS TICK] You are running in continuous mode. Check your goals, review shared memory for
  pending tasks, and take any necessary actions. Agent: {name}`
- **Periodic** sleeps `parse_cron_to_secs(cron)`, then self-prompts verbatim:
  `[SCHEDULED TICK] You are running on a periodic schedule ({cron}). Perform your routine duties.
  Agent: {name}` — note the *original string* is interpolated, so **the prompt says "every 2 hours"
  while the timer runs at 300 s.** The model will confidently report the wrong cadence.
- **Both sleep first** — no tick at boot.
- **Re-entrancy guard**: an `AtomicBool` skips a tick if the previous one is still running
  (`Periodic loop: skipping tick (busy)` / `Continuous loop: skipping tick (busy)`, both at DEBUG).
- **Global brake**: `MAX_CONCURRENT_BG_LLM = 5` — a semaphore across *all* background loops.
- **Proactive starts no loop.** It only registers triggers at spawn/boot.
- **These are `tokio::spawn` tasks, not cron jobs.** They never appear in `cron list`, cannot be
  disabled at runtime, and there is no output delivery — the response goes to the session and the
  WebSocket only.

**To stop a runaway `[schedule]`: edit `agent.toml`, remove/adjust the block, then restart the
daemon.** There is no runtime off switch. Beware seed gotcha #23 — `Agent TOML on disk differs from
DB, updating` fires for all 30 agents every boot, so **the file wins** and runtime `agent set` is
reverted. That works in your favour here.

### Proactive conditions → `parse_condition` (UPSTREAM `background.rs:174-208`)

| Condition string | TriggerPattern |
|---|---|
| `event:agent_spawned` | `AgentSpawned { name_pattern: "*" }` — **always `*`; you cannot narrow it from `agent.toml`** |
| `event:agent_terminated` | `AgentTerminated` |
| `event:lifecycle` | `Lifecycle` |
| `event:system` | `System` |
| `event:memory_update` | `MemoryUpdate` |
| `memory:<key.pattern>` | `MemoryKeyPattern { key_pattern }` |
| `all` (case-insensitive) | `All` |

**Anything else is dropped silently-ish** — `WARN Unknown event condition: {other}` or
`WARN Unrecognized proactive condition format`, then `None`, then the loop just skips it. **A typo
produces an agent that never wakes and no startup error.** Note `system:<keyword>` and `match:<text>`
exist as `TriggerPattern` variants but are **not reachable** from `agent.toml` conditions.

Auto-registration (`kernel.rs:5008-5019`) uses `max_fires = 0` (unlimited) and this prompt:
```
[PROACTIVE ALERT] Condition '{condition}' matched: {{event}}. Review and take appropriate action. Agent: {name}
```

**VERIFIED — this is where the "2 live security-auditor triggers" come from:**
```bash
grep -E "Trigger registered" /home/kyzdes/.openfang/daemon-start.log | sed -e 's/\x1b\[[0-9;]*m//g'
# INFO openfang_kernel::triggers: Trigger registered trigger_id=125a00be-… agent_id=462071d6-73f9-4772-9d29-1093e761f6c8
# INFO openfang_kernel::triggers: Trigger registered trigger_id=a8747f50-… agent_id=462071d6-73f9-4772-9d29-1093e761f6c8
sqlite3 /home/kyzdes/.openfang/data/openfang.db \
  "SELECT name FROM agents WHERE id='462071d6-73f9-4772-9d29-1093e761f6c8';"
# security-auditor
```
Two conditions → two triggers, recreated from `agent.toml` on every boot. They are **not** stored
anywhere.

---

## Triggers

### Triggers do not persist. At all.

**UPSTREAM `openfang-kernel/src/triggers.rs`:** `TriggerEngine` is two `DashMap`s
(`triggers`, `agent_triggers`) and **has no load/persist/path member and no `save` method**. Compare
`CronScheduler`, which owns `persist_path: PathBuf`.

**VERIFIED — nothing on disk or in SQLite holds them:**
```bash
sqlite3 /home/kyzdes/.openfang/data/openfang.db \
  "SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE '%trig%' OR name LIKE '%cron%' OR name LIKE '%work%' OR name LIKE '%sched%');"
# (no rows)
find /home/kyzdes/.openfang -maxdepth 3 -type d -name "triggers" ; echo "rc=$?"
# (nothing)
```

**Consequence: every trigger created with `openfang trigger create` or `POST /api/triggers` is
destroyed on daemon restart, along with its `fire_count`.** Only triggers reconstructible from
`[schedule] proactive` in `agent.toml` come back. **If a trigger must survive a restart, it must be a
`proactive` condition in `agent.toml` — there is no other durable option.**
`max_fires` is likewise lost, so a `--max-fires 10` trigger gets a fresh 10 after every restart if it
was proactive-registered (which always uses `max_fires = 0`, i.e. unlimited).

### Pattern JSON — the CLI's own examples are probably wrong

`TriggerPattern` is an **externally-tagged** serde enum with `rename_all = "snake_case"`:

```rust
enum TriggerPattern {
    Lifecycle,                                    // unit
    AgentSpawned { name_pattern: String },
    AgentTerminated,                              // unit
    System,                                       // unit
    SystemKeyword { keyword: String },
    MemoryUpdate,                                 // unit
    MemoryKeyPattern { key_pattern: String },
    All,                                          // unit
    ContentMatch { substring: String },
}
```

**Correct JSON:**
```jsonc
"lifecycle"        "agent_terminated"        "system"        "memory_update"        "all"
{"agent_spawned":      {"name_pattern": "coder*"}}
{"system_keyword":     {"keyword": "deploy"}}
{"memory_key_pattern": {"key_pattern": "agent.*.status"}}
{"content_match":      {"substring": "ERROR"}}
```

**SUSPECT — the CLI's printed examples `'{"lifecycle":{}}'`, `'{"agent_terminated":{}}'`, `'{"all":{}}'`
are almost certainly rejected.** For a unit variant serde_json's `unit_variant()` deserializes `()`,
which requires `null` — `{}` should yield `invalid type: map, expected unit`, surfacing as HTTP 400
`{"error":"Invalid trigger pattern"}` plus `WARN Invalid trigger pattern: …`. `"lifecycle"` and
`{"lifecycle":null}` should both work. **Settling test** (needs the daemon up — not run here, it is
down):
```bash
curl -sS -X POST http://127.0.0.1:4200/api/triggers -H 'Content-Type: application/json' \
  -d '{"agent_id":"<UUID>","pattern":{"lifecycle":{}},"prompt_template":"x","max_fires":1}'
# 400 {"error":"Invalid trigger pattern"}  → CLI examples are wrong; use "lifecycle"
# 201 {"trigger_id":…}                     → CLI examples are right
```
Then `DELETE /api/triggers/<trigger_id>` to clean up. **Prefer the bare-string form** — it is correct
under either outcome.

### Trigger API

```bash
B=http://127.0.0.1:4200
curl -sS $B/api/triggers | jq .                      # bare array — the CLI table works here
curl -sS "$B/api/triggers?agent_id=<UUID>" | jq .
curl -sS -X POST $B/api/triggers -H 'Content-Type: application/json' \
  -d '{"agent_id":"<UUID>","pattern":"agent_terminated","prompt_template":"Agent died: {{event}}","max_fires":0}'
# 201 {"trigger_id":"…","agent_id":"…"}
curl -sS -X DELETE $B/api/triggers/<TRIGGER_ID>
```
- `agent_id` **must** be a UUID (`{"error":"Invalid agent_id"}` otherwise). Missing → `Missing 'agent_id'`;
  missing pattern → `Missing 'pattern'`; unknown agent → 404
  `Trigger registration failed (agent not found?)`.
- `prompt_template` default `"Event: {{event}}"`; `max_fires` default `0` = unlimited.
- **`{{event}}` is the only placeholder.** It expands to the event description. `{{input}}` and cron's
  `{job}` do not exist here.
- Fields returned: `id agent_id pattern prompt_template enabled fire_count max_fires created_at`.
  Log: `INFO openfang_kernel::triggers: Trigger registered` / `Trigger fired`.
- Hand reactivation reshuffles ownership: `Took triggers for agent (pending reassignment)` →
  `Restored triggers under new agent` (`triggers.rs:165,202`).
- **`events` table is empty (0 rows) on this install** — triggers are driven by the in-process event
  bus, not by that table. Do not try to audit fired triggers from SQLite.

---

## Workflows

Multi-step agent pipelines. Definition JSON → `POST /api/workflows`. Engine:
`openfang-kernel/src/workflow.rs`, decoupled from the kernel via closures.

### Definition

```jsonc
{ "name": "code-review-pipeline", "description": "…",
  "steps": [ {
    "name": "analyze",                 // default "step"
    "agent_name": "code-reviewer",     // XOR "agent_id": "<uuid>" — exactly one required
    "prompt": "Analyze:\n\n{{input}}", // default "{{input}}"
    "mode": "sequential",              // sequential | fan_out | collect | conditional | loop
    "timeout_secs": 180,               // default 120
    "error_mode": "fail",              // fail | skip | retry
    "max_retries": 2,                  // only with error_mode "retry"; default 3
    "output_var": "analysis",          // exposes {{analysis}} to later steps
    "condition": "ERROR",              // only with mode "conditional"
    "max_iterations": 5, "until": "APPROVED"   // only with mode "loop"
  } ] }
```

- **Unknown `mode` silently falls back to `sequential`; unknown `error_mode` to `fail`.**
  `openfang-api/src/routes.rs` (`create_workflow`): `_ => StepMode::Sequential`. **`"fan-out"`,
  `"fanout"`, `"parallel"` all compile to a plain sequential step with no warning** — your parallel
  pipeline silently runs serially. The only legal spelling is **`fan_out`**.
- Variables: `{{input}}` = previous step output; `{{name}}` for any earlier `output_var`. Expansion is
  plain `String::replace` — **no escaping**; a step whose output contains `{{foo}}` will be
  re-expanded downstream.
- `fan_out`: consecutive `fan_out` steps launch together via `futures::future::join_all`, all
  receiving the same `{{input}}`. Each gets its own timeout. **Any fan-out failure aborts the whole
  workflow** regardless of `error_mode`.
- `conditional`: runs only if previous output `to_lowercase().contains(condition)`. Skipped steps do
  not modify `{{input}}`.
- `loop`: repeats ≤ `max_iterations`, terminating early when output contains `until`
  (case-insensitive). Results named `"refine (iter 1)"`, ….
- `retry`: `max_retries: 3` = **4 total attempts**, each with a full `timeout_secs`.
- Errors: `Agent not found for step '<name>'` · `Step '<name>' failed: <e>` ·
  `Step '<name>' timed out after <N>s` · `Step '<name>' failed after <N> retries: <e>` ·
  `Missing 'steps' array` · `Step '<name>' needs 'agent_id' or 'agent_name'`.

### #1253 — `collect` joins too much (CONFIRMED in source)

`workflow.rs:635`:
```rust
StepMode::Collect => {
    current_input = all_outputs.join("\n\n---\n\n");
    all_outputs.clear();
    all_outputs.push(current_input.clone());
```
…but `all_outputs.push(output)` also runs in the **sequential** branch (`workflow.rs:515`). So
`all_outputs` accumulates *every* step's output, not just the fan-out group's.

```
step1 sequential  → all_outputs = [s1]
step2 fan_out     ┐
step3 fan_out     ┘ → all_outputs = [s1, f2, f3]
step4 collect     → {{input}} = s1 + "\n\n---\n\n" + f2 + "\n\n---\n\n" + f3   ← s1 should not be there
```
The docs claim collect "gathers all outputs from the preceding fan-out group". It does not.
**Workaround: make the fan-out group the first thing in the workflow, or put the pre-fan-out step's
value in an `output_var` and reference it explicitly rather than relying on collect's join order.**
`collect` executes no agent — it is data-only, and it *does* clear afterwards, so a second fan-out
group's collect sees `[joined_first_group, g2a, g2b]`.

### #1192 — deleted workflows resurrect (CONFIRMED in source)

- `POST /api/workflows` **writes `~/.openfang/workflows/<uuid>.json`** (routes.rs, "Persist workflow
  to disk so it survives daemon restarts (#751)").
- `DELETE /api/workflows/{id}` calls `workflows.remove_workflow(id)` →
  `self.workflows.write().await.remove(&id)` — **in-memory map only. The file is never touched.**
- At boot `load_workflows_from_dir` re-registers every `*.json`, preserving the original `id`
  (`register` uses `workflow.id` from the file).

**Fix — delete the file too:**
```bash
ls -la /home/kyzdes/.openfang/workflows/ 2>/dev/null   # does not exist on this install (no workflows)
curl -sS -X DELETE http://127.0.0.1:4200/api/workflows/<ID>
rm -f /home/kyzdes/.openfang/workflows/<ID>.json       # ← without this it comes back on restart
```
Boot log lines: `Auto-loaded workflow` · `Invalid workflow JSON, skipping` ·
`Failed to read workflows directory` · `Failed to create workflows dir:`.
Directory override: config `workflows_dir`, default `<home>/workflows`. It is only scanned **if it
already exists** — created lazily on first workflow create.

### Workflow API / CLI

```bash
B=http://127.0.0.1:4200
curl -sS $B/api/workflows | jq .                    # [{id,name,description,steps:<count>,created_at}]
curl -sS -X POST $B/api/workflows -H 'Content-Type: application/json' -d @wf.json   # 201 {"workflow_id":"…"}
curl -sS -X POST $B/api/workflows/<ID>/run -H 'Content-Type: application/json' -d '{"input":"…"}'
curl -sS $B/api/workflows/<ID>/runs | jq .
```
`openfang workflow list|create <FILE>|get|update|delete|run` all work against these (create reads
`workflow_id` correctly, unlike cron). Note `"steps"` in the list response is an **integer count**,
not the array.

**Cron → workflow:** `{"action":{"kind":"workflow_run","workflow_id":"…"}}` accepts a **UUID or a
name** (name lookup falls back to `list_workflows().find(|w| w.name == workflow_id)`). Failure:
`workflow not found: <x>`. This is the only place in the automation surface where a name is
officially accepted.

---

## Hands

9 bundled, SHA-256 pinned, compiled into the binary (`openfang-hands/src/bundled.rs`, `include_str!`
of `bundled/<id>/{HAND.toml,SKILL.md}`): **browser, clip, collector, infisical-sync, lead, predictor,
researcher, trader, twitter**.

```bash
openfang hand list | active | info <ID> | check-deps <ID> | install-deps <ID>
openfang hand install <PATH>                  # local dir containing HAND.toml
openfang hand activate <ID> [-n NAME]         # -n required to run 2 instances of one hand
openfang hand deactivate | pause | resume
openfang hand config <ID> [--get K | --set K=V | --unset K | --list]   # --list is the default
curl -sS http://127.0.0.1:4200/api/hands ; curl -sS http://127.0.0.1:4200/api/hands/active
```

`HAND.toml`: `id name description category icon tools[]`, then `[[settings]]`
(`key label description setting_type` ∈ `text|select|toggle`, `default`) with `[[settings.options]]`
(`value`, `label`), then `[dashboard]` / `[[dashboard.metrics]]` (`label`, `memory_key`, `format` ∈
`number|text`).

**Activating a hand starts a cost meter.** UPSTREAM: every "Einstein" hand is asserted by
`bundled.rs` tests to carry `schedule_create`, `schedule_list`, `schedule_delete`, and its `SKILL.md`
instructs the model to create its own cron on first run — e.g. collector: *"1. Create collection
schedule using schedule_create based on `update_frequency`"*; researcher: *"3. Create your delivery
schedule using schedule_create based on `delivery_schedule` setting"*. **The hand writes real cron
jobs into `cron_jobs.json` on its first turn.** After activating, always check:
```bash
curl -sS http://127.0.0.1:4200/api/cron/jobs | jq '.total, .jobs[]|{name,schedule,agent_id}'
```
Frequency comes from a `[[settings]]` select — collector's `update_frequency` defaults to `daily`
with options `hourly | every_6h | daily | weekly`. **Set it before activation**, not after.

**Dashboard metrics are LLM-maintained, not instrumented.** `[[dashboard.metrics]].memory_key` points
at a plain agent-memory key that the model is *asked* to update (`memory_store
collector_hand_data_points`, `…_entities_tracked`, `…_reports_generated`, `…_last_update`). If the
model skips the step — as it will on any tick where it decides there is nothing to do — **the metric
silently stays stale**. Blank/frozen hand metrics mean the model didn't call `memory_store`, not that
the hand is idle. Read the underlying key directly:
```bash
openfang memory get <AGENT> collector_hand_last_update
```

Reactivation is destructive-ish and re-homes automation:
`Removing existing hand agent for reactivation` → `Reassigned triggers after hand reactivation` →
`Restored cron jobs after hand reactivation` → `Hand activated with agent` (`kernel.rs:3924-3999`).
Cron reassignment is also automatic on agent replacement (`Reassigned cron jobs to new agent`,
`cron.rs:280`) and cleanup on delete (`Removed cron jobs for deleted agent`, `cron.rs:306`).
Instance state: `hand_state.json`; failure logs `Failed to persist hand state`.

---

## Skills

- **61 skills are compiled INTO the 66 MB binary.** Boot logs `Loaded 61 bundled skill(s)`. There is
  no `~/.openfang/skills/`. Per-agent user skills live in `workspaces/<agent>/skills/`.
- **`openfang skill list` prints `No skills installed` anyway, and `/api/skills` returns empty** — the
  list path enumerates only *user* skills. VERIFIED (seed). **This is cosmetic. Do not "fix" it by
  reinstalling skills.** To see what an agent can actually run, use the agent-facing `skill_list` /
  `skill_describe` tools, or `GET /api/agents/{id}/skills`.
- Two kinds: **prompt-only** (Markdown injected into context) and **executable (WASM)**. The web UI
  refuses the latter: `Only prompt_only skills can be created from the web UI`.
- New skills need a restart: `Restart the daemon to load the new skill, or it will be available on
  next boot.` Hot reload exists but is conditional: `Skill registry hot-reloaded` vs
  `Skill registry is frozen (Stable mode)`.
- Config injection via `SKILL.md` frontmatter landed in 0.6.0. `Failed to persist skill config:` on
  write failure. Name validation: `Skill name must contain only letters, numbers, hyphens, and underscores`.
- Ecosystem is **ClawHub** (clawhub.ai, `/api/clawhub/*`) — **the CLI help still says "FangHub"**.
- WASM limits: fuel 1,000,000, 30 s timeout. **#1242 `max_memory_bytes` is never enforced; #1241 WASM
  watchdog threads accumulate.** Do not rely on WASM memory caps.

---

## Cost model — what the schedules actually burn

**VERIFIED, live:**
```bash
D=/home/kyzdes/.openfang/data/openfang.db
sqlite3 -header $D "SELECT a.name, count(*) calls, sum(u.input_tokens) inp, sum(u.output_tokens) outp
  FROM usage_events u LEFT JOIN agents a ON a.id=u.agent_id GROUP BY a.name ORDER BY inp DESC LIMIT 8;"
# name|calls|inp|outp
# orchestrator|54|413317|2755
# ops|7|57981|662
# assistant|2|34966|935
# health-tracker|1|28842|191
sqlite3 $D "SELECT count(*), sum(input_tokens), sum(output_tokens),
  round(1.0*sum(input_tokens)/sum(output_tokens),1) FROM usage_events;"
# 64|535106|4543|117.8
sqlite3 $D "SELECT min(timestamp), max(timestamp) FROM usage_events;"
# 2026-07-13T19:33:53…|2026-07-14T08:12:50…
```

**117.8 input tokens per output token.** Every LLM call on this install but two came from an
autonomous loop. `orchestrator` alone: 54 calls, 413,317 input, 2,755 output — **avg 7,654 in / 51
out per tick (150:1)**, i.e. a full context re-sent every 120 s to emit one sentence of
"No actionable items".

Projected steady-state (interval → runs/day × measured avg input):

| Agent | Mode | Runs/day | Avg in/tick | **Input tokens/day** |
|---|---|---|---|---|
| orchestrator | continuous 120 s | 720 | 7,654 | **~5.5 M** |
| ops | periodic `every 5m` (#1206) | 288 | 8,283 | **~2.4 M** |
| health-tracker | periodic `every 1h` | 24 | 28,842 | **~0.7 M** |
| security-auditor | proactive | only on spawn/terminate | — | ~0 while idle |
| | | | **total** | **≈ 8.6 M/day for ≈ 55 K output** |

**#1206 is live and worse than it reads:** `ops/agent.toml` ships `every 5m` = 288 runs/day, and
`orchestrator`'s 120 s continuous loop is **2.5× worse still** and is not mentioned in the issue.

**What does and does not brake this:**
- **`[resources] max_llm_tokens_per_hour` in `agent.toml` is the only real brake** (seed #12).
  Live values: ops 50,000/h, health-tracker 100,000/h, security-auditor 150,000/h, orchestrator
  500,000/h. **ops needs ~99,400/h (12 ticks × 8,283) against a 50,000/h cap — it is throttled
  roughly half the time.** orchestrator needs ~230,000/h against 500,000/h — **unthrottled.**
- **Budget enforcement is INERT.** `/api/budget` reports all `0.0` and every `usage_events.cost_usd`
  is `0.0`, because `custom_models.json` carries `input_cost_per_m = 0.0` for gonka/NIM.
  **Dollar limits (`max_hourly_usd` etc.) do nothing here. Never reason about spend from
  `/api/budget` on this box.**
- `MAX_CONCURRENT_BG_LLM = 5` caps concurrency, not volume.
- **#1252 compounds it**: idle agents get marked Crashed and auto-recovered (`Unresponsive Running
  agent marked as Crashed for recovery` → `Auto-recovering crashed agent (attempt 1/3)`), each
  recovery costing more provider calls. The reporter measured ~570 extra calls/day.

**Cheapest safe reductions**, in order: raise `orchestrator`'s `check_interval_secs` (120 → 3600 is a
30× cut) → raise `ops` to `every 1h` → drop `[schedule]` entirely from agents you do not use
(reactive is the default). All require an `agent.toml` edit + daemon restart.

---

## Recipes

Read the [safety rules](#hard-rules) first. Everything below that mutates state requires explicit
user approval and a running daemon.

### Recipe: scheduled agent that posts to Telegram (the canonical task)

**The whole task is the mechanism choice, and the obvious choice is wrong. "Runs every 30 minutes"
points at `[schedule]`, and `[schedule]` has no delivery. Use a cron job. Do not use both** — see
[the `[schedule]` pointer](#schedule-in-agenttoml).

Five steps, in order. **Steps 2 and 4 are mutating and need explicit user approval.**

**Step 1 — write the manifest.** `~/.openfang/agents/reporter/agent.toml`; the directory name **must**
equal `name`. Full field reference: `agents.md`.

```toml
name = "reporter"                    # MUST equal the directory name
version = "0.1.0"
description = "Periodic reporter — posts a digest to Telegram every 30 minutes."
module = "builtin:chat"

[model]
provider = "default"                 # both "default" → inherits the [default_model] overlay
model = "default"
max_tokens = 4096
temperature = 0.3
system_prompt = """Produce ONE short status digest per run. 3-6 bullets, no preamble."""

[resources]
max_llm_tokens_per_hour = 100000     # the only brake that actually bites — see Cost model

[capabilities]
tools = ["file_read", "file_list", "memory_store", "memory_recall"]
memory_read  = ["*"]                 # DECLARE THESE. Granting memory_* tools without scopes may
memory_write = ["self.*"]            # leave them granted-but-scope-denied — the default for an
agent_spawn  = false                 # OMITTED array is UNVERIFIED. All 30 bundled manifests declare
network      = ["*"]                 # all of them; do not be the first to omit. -> agents.md
# NO channel_send — cron delivery is a kernel path, not a tool call.
# See "Does fan-out respect the agent's [capabilities]?"

# NO [schedule] SECTION. Deliberate. The cron job in step 4 is the timer.
# [schedule] here would add a SECOND timer that delivers nothing → 2× spend.
```
📎 **`agents.md` → "Minimal correct manifest for this install" is the canonical block** — the
`[capabilities]` semantics and the omitted-array question live there, not here. If the two ever
disagree, `agents.md` wins.
**Get `temperature`/`max_tokens` right on the FIRST write** — `agents.md` ("TOML on disk vs DB"):
neither is in the boot-time `changed` diff, so later edits are **silently ignored forever** until
the agent is deleted and recreated.

**Step 2 — start the daemon.** ⚠️ **This is the riskiest step in this recipe and it mutates a
production box (30 agents, a live Telegram bot) — get explicit user approval first.** It is
unavoidable: the cron API needs the daemon, and **the agent has no UUID until boot auto-spawns the
new directory** — that auto-spawn is what mints it (`agents.md` → "Creating an agent end to end").
That is *why* the manifest in step 1 must exist before this start, not after.

Canonical command — never bare `nohup` (dies with the terminal's cgroup), never `--scope` (blocks):
```bash
systemctl --user reset-failed openfang 2>/dev/null
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start
for i in $(seq 30); do
  [ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:4200/api/health)" = 200 ] \
    && { echo up; break; }; sleep 2; done
```
Rationale and the cgroup/log traps: `daemon-lifecycle.md`.

**Step 3 — get the UUID.** Cron takes a **UUID, never a name**.
```bash
B=http://127.0.0.1:4200
AID=$(curl -sS $B/api/agents | jq -r '.[]|select(.name=="reporter").id')
# daemon down? → sqlite3 …/data/openfang.db "SELECT id FROM agents WHERE name='reporter' LIMIT 1;"
```

**Step 4 — create the job over HTTP. NOT `openfang cron create`** (broken three ways — see the table
above; it prints `Failed: ?` on success, so **retrying it creates duplicate jobs**).
```bash
curl -sS -X POST $B/api/cron/jobs -H 'Content-Type: application/json' -d "{
  \"agent_id\": \"$AID\",
  \"name\": \"reporter-30m\",
  \"schedule\": {\"kind\":\"cron\", \"expr\":\"*/30 * * * *\", \"tz\":\"Europe/Warsaw\"},
  \"action\":   {\"kind\":\"agent_turn\", \"message\":\"Produce the 30-minute status digest.\",
                 \"timeout_secs\": 300},
  \"delivery\": {\"kind\":\"none\"},
  \"delivery_targets\": [
    {\"type\":\"channel\", \"channel_type\":\"telegram\", \"recipient\":\"83979215\"}
  ],
  \"one_shot\": false
}" | jq -r '.result | fromjson'
# { "job_id": "…", "status": "created" }      ← the VALUE of .result is itself JSON: fromjson it ONCE
```

**"Every 30 minutes" is a different string in each dialect, and the wrong one fails silently:**

| Dialect | Correct string | Your string used here instead |
|---|---|---|
| `agent.toml [schedule]` | `every 30m` | `*/30 * * * *` → **silently 300 s = 48 runs/h** |
| `schedule_create` tool | `every 30 minutes` | `every 30m` → hard error |
| **cron API (above)** | `*/30 * * * *` | `every 30m` → `must have exactly 5 fields (got 2)` |

`{"kind":"every","every_secs":1800}` also works (**60 ≤ n ≤ 86400**) but fires 30 min after
*creation* and drifts; `*/30 * * * *` fires on the wall clock at :00/:30. `every` is **unreachable
from the CLI**. For a one-shot use `{"kind":"at","at":"2026-08-01T09:00:00Z"}` **with
`"one_shot": true`** or it re-fires every 15 s forever.

Body checklist: **UUID not name** · **`expr` = 5 fields, digits and `*/-,?` only — letters are
rejected** · **`type` not `kind` inside `delivery_targets`** (everywhere else it is `kind`) ·
`timeout_secs` ∈ 10..600 · `recipient` is the literal Telegram id (this install's
`allowed_users = ["83979215"]` — see `channels.md`).

**Why `delivery: none` + the real target in `delivery_targets`:** both fire independently.
`delivery_targets` fan out via `join_all` and **never fail the job**; legacy `delivery` failure calls
`record_failure` → counts toward the **5-strike auto-disable, and nothing re-enables a disabled
job**. A Telegram blip must not permanently kill the schedule.

**Why a literal `recipient`, not `{"kind":"last_channel"}`:** a brand-new agent has never sent
anything, so its `delivery.last_channel` key does not exist — and a missing key **records SUCCESS**.
The job would report `last_status:"ok"` forever while posting nothing. On this install exactly one
of 30 agents (`assistant`) has the key; `reporter` would not.

**Step 5 — verify. There are four independent ways this looks healthy while posting nothing, so
`last_status` is not evidence. Only the phone is.**

```bash
curl -sS $B/api/cron/jobs | jq '.total, (.jobs[]|{id,name,enabled,next_run,schedule})'
JOB=$(curl -sS $B/api/cron/jobs | jq -r '.jobs[]|select(.name=="reporter-30m").id')
curl -sS -X POST $B/api/cron/jobs/$JOB/run     # fire once now; does not disturb next_run
grep -E "Cron fan-out|Auto-disabling cron job" /home/kyzdes/.openfang/daemon-start.log | tail -10
```
| Check | Passes when | Silent failure it catches |
|---|---|---|
| `total` is 1, not 2 | exactly one job | `cron create`'s `Failed: ?` → you retried → duplicates |
| `next_run` is **populated** | non-null | null `next_run` → the job never fires |
| `enabled: true` | true | 5 consecutive failures → auto-disabled, permanently |
| `delivery_targets` echoed back non-empty | present | **key-name typo → delivery silently defaults to none** |
| **the message is in Telegram** | it arrived | everything above passing while nothing was sent |

**Fan-out *successes* log at DEBUG and are invisible at the default `log_level`** — only
`Cron fan-out: channel delivery failed` shows up. Absence of errors in the log is **not** proof of
delivery. **Check the phone.**

⚠️ **"Just raise `log_level` to debug" is NOT a one-liner here — read this before trying:**
`log_level` **does not exist in this `config.toml` at all** (VERIFIED — the only sections are
`[channels.telegram] [default_model] [[fallback_providers]]×4 [memory] [provider_urls]`). It is a
**root** key, not a section key; its default is `info`; and **changing it live does nothing** — the
daemon reads it at boot, so you need a `config.toml` edit **plus a restart of the production daemon**
(`config-reference.md`). `openfang config set` is on the MUST-NOT list above *and* strips all TOML
comments. **Prefer `RUST_LOG` instead** — it needs no write to the user's config and composes with
the canonical start:
```bash
systemd-run --user --unit=openfang --collect --setenv=RUST_LOG=openfang_kernel::cron=debug \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start
```
**SUSPECT** — the `RUST_LOG` *mechanism* is documented VERIFIED (`cli-reference.md`,
`config-reference.md`), but this exact target string has not been confirmed against a live daemon.

### Run an existing agent every N and deliver elsewhere

Same as step 4 above with a different `$AID`, `expr`, and `delivery_targets`.

### React to an event

Durable (survives restart) — the only durable option:
```toml
# agents/<name>/agent.toml — then restart the daemon
[schedule]
proactive = { conditions = ["event:agent_terminated"] }
```
Ephemeral (gone on restart), with a narrower pattern than `agent.toml` allows:
```bash
curl -sS -X POST http://127.0.0.1:4200/api/triggers -H 'Content-Type: application/json' -d '{
  "agent_id": "<UUID>",
  "pattern": {"agent_spawned": {"name_pattern": "coder*"}},
  "prompt_template": "New coder agent: {{event}}. Audit its capabilities.",
  "max_fires": 0
}'
```
**Triggers have no delivery.** The agent's response goes to its session and the WebSocket only. To get
an event-driven message out, the trigger prompt must instruct the agent to call the `channel_send`
tool itself.

### Deliver results to several places at once

```jsonc
"delivery": {"kind":"none"},
"delivery_targets": [
  {"type":"channel",    "channel_type":"telegram", "recipient":"83979215"},
  {"type":"local_file", "path":"/home/kyzdes/reports/daily.md", "append": true},
  {"type":"webhook",    "url":"https://example.com/hook", "auth_header":"Bearer xyz"},
  {"type":"email",      "to":"me@example.com", "subject_template":"Daily: {job}"}
]
```
**`"append": true` or the file is truncated every run.** `{job}` is single-braced. Fan-out failures
never fail the job, so **check the logs, not the job status**:
```bash
grep -E "Cron fan-out" /home/kyzdes/.openfang/daemon-start.log | tail -30
```
Successes log at DEBUG. Getting positive confirmation is **not** a one-liner — see the `log_level` /
`RUST_LOG` caveat under "Step 5 — verify". Absence of errors is not proof of delivery.

### Diagnose "the scheduled agent isn't doing anything"

```bash
L=/home/kyzdes/.openfang/daemon-start.log
grep -E "background loop|Trigger registered|Cron scheduler active|Loaded cron jobs" $L | sed -e 's/\x1b\[[0-9;]*m//g' | tail -20
grep -c "Unparseable cron" $L                       # >0 → your [schedule] cron is running at 300s
grep -E "Unknown event condition|Unrecognized proactive" $L | tail -10   # → typo'd proactive condition
grep -E "Auto-disabling cron job|Cron fan-out.*failed|Cron job failed" $L | tail -20
cat /home/kyzdes/.openfang/cron_jobs.json | head -40
```
Decision table:
| Symptom | Cause |
|---|---|
| Agent ticks on time but **nothing is ever delivered**, and it is not in `cron list` | **it is a `[schedule]` agent — `[schedule]` has no delivery.** Rebuild it as a [cron job](#recipe-scheduled-agent-that-posts-to-telegram-the-canonical-task) |
| Agent runs **twice** per interval; only one run delivers | `[schedule]` **and** a cron job on the same agent — two independent timers. Remove the `[schedule]` block |
| No `Starting … background loop` line | no `[schedule]`, or `proactive` (starts no loop) |
| Loop starts, `interval_secs=300` ≠ what you wrote | Dialect 1 fallback — see [The three dialects](#the-three-dialects) |
| `proactive` agent never wakes | `parse_condition` returned `None` (typo) → grep the warns |
| Trigger vanished | triggers are memory-only; the daemon restarted |
| Cron job `enabled:false` you didn't set | 5 consecutive failures → auto-disabled |
| `last_status:"ok"` but nothing arrived | `last_channel` key missing → silent no-op success |
| Cron fires but no output anywhere | `delivery`/`delivery_targets` key typo → silently defaulted to none |
| `cron create` said `Failed: ?` | **it probably succeeded** — check `GET /api/cron/jobs` before retrying |
| Deleted workflow is back | #1192 — the `workflows/<id>.json` file was never removed |
| Parallel workflow runs serially | `mode` misspelled → silently `sequential`. Only `fan_out` works |

---

## Hard rules

**MUST NOT** (mutating / cost-incurring — never without explicit user approval):
`openfang start|stop|restart` · `cron create|delete|enable|disable` · `trigger create|delete` ·
`workflow create|update|delete|run` · `hand activate|deactivate|pause|resume|config --set|install` ·
`skill install|create|remove` · `agent set|kill|spawn` · `config set|unset|edit` · `reset` ·
`uninstall` · `doctor --repair` · `--yolo` · **any POST/PUT/DELETE to 127.0.0.1:4200**.

**CAN — but "read-only" ≠ "free". This list MUST mirror SKILL.md's two tiers; it used to flatten
them and told you `status` was free. It is not.**

*Free at any time, daemon up or down (audit delta **0**, VERIFIED):* `--help` on anything ·
`curl … /api/health` ← always start here · `openfang health` · `doctor --json` (never `--repair`) ·
reads under `~/.openfang` · `sqlite3 -readonly` SELECT with LIMIT · **GET** on 127.0.0.1:4200
(no trailing slash) · bounded `strings`/`grep` on the binary.

*⚠️ **+9 irreversible `audit_entries` rows each when the daemon is DOWN** — cheap only once `health`
is `200`:* `status` · `agent list` — each boots an in-process kernel and re-stamps 30 manifests.
**UNVERIFIED whether these boot a kernel too — assume they cost:** `cron list` · `trigger list` ·
`workflow list` · `hand list|active` · `skill list` · `logs` · `sessions` · `security
audit|status|verify` · `memory list|get`. → SKILL.md "MUST NOT / CAN", `gotchas.md` G12.

**Environment traps that bite automation work:**
- **`openfang start` runs FOREGROUND, and piping it to `head` sends SIGPIPE and kills the daemon.**
  Detach with the canonical command — **not** `nohup … & disown` (disown does not leave the terminal's
  systemd cgroup, so systemd-oomd takes the daemon down with the terminal — VERIFIED) and **not**
  `--scope` (it blocks). Full detail: `daemon-lifecycle.md`.
  ```bash
  systemd-run --user --unit=openfang --collect \
    -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
    ~/.openfang/bin/openfang start
  ```
- `--yolo` auto-approves every tool call including `shell_exec` for all 30 agents (`network=["*"]`).
  **A scheduled agent under `--yolo` is an unattended shell with a 5-minute timer.** Never combine.
- `config set` / `config unset` **strip all TOML comments**.
- `openfang.db` is `0644` and holds full transcripts of every autonomous tick.
- WAL (733 KB) is not checkpointed — copying `openfang.db` alone gives a stale snapshot.
- Trailing-slash routes 404 (`/api/agents/`) while the non-slash form 200s — **even though the slash
  forms are the string literals in the binary.**
- `chat`, `message`, `memory`, `sessions` take an agent **name**; `agent chat`, `agent kill`,
  `trigger create`, and **the cron HTTP API** take a **UUID**. `cron create`'s `<AGENT>` arg claims to
  take either and does not.
- Config parse failure degrades to defaults **silently** (`Failed to parse config, using defaults`) —
  which would drop `max_cron_jobs` to its default without warning.
