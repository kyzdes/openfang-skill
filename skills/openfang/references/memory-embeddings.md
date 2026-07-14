# OpenFang memory & embeddings (v0.6.9)

**Read this when:** anything touches the `memories` / `entities` / `relations` / `kv_store` /
`canonical_sessions` tables; `[memory]` config keys; embeddings, vector recall, or "why is
`embedding` NULL"; the `memory_store` / `memory_recall` / `knowledge_*` tools; the
`openfang memory` CLI; or the compactor (`compaction_cursor`, `compacted_summary`).

All commands below are **read-only**. The daemon on this install is **DOWN** (OOM-killed); claims
needing a live daemon are marked UNVERIFIED. Do **not** start it to check something.

Timezone discipline: **DB timestamps are UTC (`+00:00`); `journalctl` prints local (`+02:00`)**.
Every cross-source correlation below is stated in UTC. Getting this wrong inverts the whole story.

---

## FIRST: "semantic memory" = embeddings + vector recall. There is no `scope` toggle.

If you were asked to "turn on semantic memory", you are being asked about **embeddings**. Read
[Enable embeddings from scratch](#enable-embeddings-from-scratch-the-ordered-procedure). Do **not**
go hunting for a `scope` setting — **three different things in this codebase are named "semantic",
and none of them is a switch:**

| "semantic" thing | What it actually is |
|---|---|
| `memories.scope` column | **A decoy.** Defaults to `'episodic'`; nothing ever writes another value. |
| `crates/openfang-memory/src/semantic.rs` | **The whole SQLite memory store.** Not a semantic-only module — it holds the `memories` INSERT *and* the recall SELECT. |
| `-- Semantic memories` (schema comment) | The comment above `CREATE TABLE memories`. In OpenFang's own vocabulary the **entire `memories` table is "semantic memory"**, embedded or not. |

VERIFIED — the whole binary contains exactly **two** occurrences of `episodic` and **zero** of
`semantic` as a scope value:
```bash
strings -n 10 /home/kyzdes/.openfang/bin/openfang | grep -iE 'episodic' | cut -c1-220
```
```
DurationIfXult32Vslt32x4uunarrowwestmerex-euc-jpPrecedescupbrcapHTTP/1.0timelinemsg_typeauth_urlSocketV6markdownepisodichome_dirThursdayskill.mdworkflow
            scope TEXT NOT NULL DEFAULT 'episodic',
```
One is the schema `DEFAULT`, one is a bare word in the string blob (the Rust-side default). There is
**no scope enum, no `scope='semantic'` code path, and no config key that produces one.** The
`-- Semantic memories` comment is the header of `CREATE TABLE memories` itself:
```bash
strings -n 8 /home/kyzdes/.openfang/bin/openfang | grep -B1 -A4 -- '-- Semantic memories'
```
```
        -- Semantic memories
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            agent_id TEXT NOT NULL,
            content TEXT NOT NULL,
```
**`scope` is a caller-supplied bind parameter (`?5`) that only ever receives `'episodic'`.** An
operator who greps for a way to write `scope='semantic'` is chasing a value the binary cannot
produce. Live data agrees — `SELECT DISTINCT scope, hex(scope)` → `episodic|657069736F646963|64`
(and note `scope` is **not** double-encoded, unlike `source`).

Also a decoy: `'general'` appears 4× in `strings` but every hit is **dashboard JavaScript**
(`c.category || 'general'` — command-palette categories), not a scope. VERIFIED.

---

## The four things that waste the most time (read first)

1. **`openfang memory` is the KV store ONLY. It does not read the `memories` table.** There is
   **no CLI for episodic memories at all** — `sqlite3` or the `memory_recall` tool are the only
   ways in. An operator who runs `openfang memory list <agent>` to "see the agent's memories"
   sees a different table and concludes memory is empty. VERIFIED (below).
2. **`memories.source` is double-encoded — stored as `"conversation"` *with literal quotes*.**
   `WHERE source='conversation'` returns **0** rows. You must write `WHERE source='"conversation"'`.
   VERIFIED (below). Same bug class as `agents.state`.
3. **Embedding failures are silent and permanent.** A failed embedding call does **not** fail the
   store — the row is written with `embedding = NULL` and **never retried**. **There is no backfill
   path in the binary.** 58 of 64 rows here are permanently unembeddable. VERIFIED (below).
4. **The embedding driver AUTO-DETECTS a local ollama on `localhost:11434` with zero `[memory]`
   config.** It was calling ollama for ~10 hours before anyone configured it. Setting
   `embedding_provider` did **not** turn embeddings on — `ollama pull` did. VERIFIED (below).

---

## Enable embeddings from scratch (the ordered procedure)

**The order is the whole point. `ollama pull` is the step that turns embeddings on — not the config
edit.** On this install the config was written at `07:54:57`, but embeddings had already started
working at `07:54:36` when the model landed. Doing this in the wrong order gives you a silent 404
storm and a permanent population of `embedding = NULL` rows that **no command can ever repair**
(see [the mechanism](#the-mechanism-why-null-is-permanent)).

> **This procedure is WRITE-heavy and is NOT for a read-only session.** It is reconstructed from the
> driver-selection order + the verified timeline below. Each *verification* command is VERIFIED; the
> end-to-end procedure is **UNVERIFIED as a sequence** — the daemon here is down
> (`curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:4200/api/health` → `000`) and was not
> started to test it.

> ## 🛑 STEP 0 — ARE THEY ALREADY ON? Run this BEFORE anything below.
> **On this install the answer is YES, and the correct action is: do nothing.** Embeddings went live
> at `2026-07-14T07:55:07Z`, `[memory]` already reads `embedding_provider = "ollama"` /
> `embedding_model = "mxbai-embed-large"`, and the model is already pulled. **The procedure below
> starts with `stop` — running it here would take down a production daemon and a live Telegram bot to
> re-write config that already says the right thing.** This procedure is for a box where embeddings
> are genuinely OFF. It is **not idempotent**; nothing below re-checks that for you.
> ```bash
> sqlite3 -readonly ~/.openfang/data/openfang.db \
>   "SELECT COUNT(*), length(embedding) FROM memories WHERE embedding IS NOT NULL GROUP BY 2;"
> # 6|4096  => vectors exist at the right width (1024 f32 = mxbai-embed-large). ON. STOP HERE.
> # zero rows => embeddings have never once succeeded. Only then continue.
> ```
> Full reasoning: Signals 1/2/4 in "The evidence" below. Run them first; they cost 0 audit rows.

```bash
# 1. PULL THE MODEL FIRST. This is the step that actually enables embeddings.
#    Skipping/reordering this is the failure mode this entire file documents.
ollama pull mxbai-embed-large
curl -s -m 5 http://127.0.0.1:11434/api/tags | grep -o 'mxbai-embed-large'   # MUST print before continuing

# 2. STOP the daemon before editing config. The driver binds ONCE at boot; there is no reload.
#    Skip this if `curl … /api/health` already returns 000 — it is already down.
openfang stop

# 3. Edit ~/.openfang/config.toml
#    [memory]
#    embedding_provider = "ollama"           # the ONE embedding path that works (#1212)
#    embedding_model    = "mxbai-embed-large"

# 4. START — the canonical command (SKILL.md #1). NEVER bare `openfang start`: it runs in the
#    FOREGROUND, hangs your tool call, and dies with your shell.
systemctl --user reset-failed openfang 2>/dev/null
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start

# 5. VERIFY — but GATE ON FRESHNESS FIRST. Config alone proves nothing, and neither does a grep
#    of a stale log (see the warning below).
for i in $(seq 30); do
  [ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:4200/api/health)" = 200 ] \
    && { echo up; break; }; sleep 2; done
grep -a 'Embedding driver' ~/.openfang/daemon-start.log | tail -1   # want: "configured from memory config"
```

🔴 **The freshness gate in step 5 is load-bearing — without it the check is a FALSE POSITIVE.**
`grep -a 'Embedding driver' ~/.openfang/daemon-start.log` **passes with the daemon DOWN**. VERIFIED:
with `health` → `000`, that grep still prints
`[2026-07-14T07:55:07.257446Z INFO openfang_kernel::kernel: Embedding driver configured from memory
config provider=ollama …` — from the **previous** boot. The file is frozen at the `08:36:41Z`
shutdown, so the designated success string sits in a stale file and will "confirm" any future boot,
**including one that never happened**. Gate on `health` → `200` first, or bound it with
`journalctl --user -u openfang --since "1 min ago"`. A check that proves nothing *convincingly* is
worse than no check.

**Verification is not optional.** `embedding_provider` in `config.toml` is **not evidence** that
embeddings work — the driver **auto-detects** ollama with zero config (proven by the 276 pre-config
404s below), and a *missing model* fails silently. Config and reality are independent. Prove it with
the section below.

**Why the model must exist before the driver runs:** the embedding path has **no 404 handler**. The
chat path prints `` Model not found on Ollama. Run `ollama pull <model>` first. `` — the embedding
path prints nothing a user sees. Every store during a missing-model window is silently and
permanently NULL-embedded.

**Choosing a model:** pick one from the compiled dims table (see [Storage format](#storage-format)),
or `vector_dims` will be wrong (#1251). `mxbai-embed-large` is in the table. If nothing is set at
all, the default is `text-embedding-3-small` — an **OpenAI** model, i.e. off-box. Do not leave it
unset on a privacy-sensitive install.

---

## How to prove embeddings are live WITHOUT starting the daemon

The direct proof (`Vector recall: ` in the log) is DEBUG-level and **structurally unavailable**
read-only — see [Does recall use the embeddings?](#does-recall-use-the-embeddings). Use this
four-signal proxy instead. **Signals 1–2 prove vectors are being produced and stored; that is the
strongest claim available read-only. No read-only check proves the *ranking* consumed them.**

**Signal 1 — vectors physically exist, at the right width.** The decisive one.
```bash
DB=/home/kyzdes/.openfang/data/openfang.db
sqlite3 -readonly $DB "SELECT COUNT(*), length(embedding) FROM memories WHERE embedding IS NOT NULL GROUP BY 2;"
```
```
6|4096
```
VERIFIED. `4096` bytes = 1024 × f32 = `mxbai-embed-large`'s 1024 dims. A wrong width means a
model/dims mismatch; **zero rows means embeddings have never once succeeded.**

**Signal 2 — the NULL/non-NULL split is temporal, not random.** This is what distinguishes *"fixed
in the past"* from *"broken right now"*, and it is the check most operators miss.
```bash
sqlite3 -readonly $DB "SELECT embedding IS NOT NULL AS emb, COUNT(*), MIN(created_at), MAX(created_at) FROM memories GROUP BY 1;"
```
- **Zero temporal overlap** (all NULLs older than all embedded rows) → embeddings were **fixed at a
  point in time**; the NULLs are a permanent historical artifact. **Nothing is broken. Do not
  backfill.** ← this install
- **Interleaved** (NULLs still appearing *after* embedded rows) → embeddings are **failing right
  now**, intermittently. Go read the ollama journal.

Confirm the split with the two counts that must both be `0` (substitute your own cutover instant):
```bash
sqlite3 -readonly $DB "SELECT COUNT(*) FROM memories WHERE embedding IS NULL     AND created_at > '2026-07-14T07:57';"  # -> 0
sqlite3 -readonly $DB "SELECT COUNT(*) FROM memories WHERE embedding IS NOT NULL AND created_at < '2026-07-14T07:57';"  # -> 0
```

**Signal 3 — ollama served the requests.** The authoritative 200-vs-404 check:
```bash
sudo journalctl -u ollama --no-pager -n 200 | grep -a '/v1/embeddings' | tail -5
```
**This needs root and assumes ollama is a systemd unit.** If ollama runs as a bare user process, in
Docker, or on a non-systemd box, this check is simply **unavailable** — there is no OpenFang-side
equivalent, and `openfang doctor` does not check it. Fallbacks, in order:
```bash
# Docker:
docker logs --tail 200 ollama 2>&1 | grep -a '/v1/embeddings' | tail -5
# user process — ollama only journals to its own stdout; find where that went:
journalctl --user -u ollama --no-pager -n 200 | grep -a '/v1/embeddings' | tail -5
```
If none is available, **fall back to Signal 4**, which needs no logs at all.

**Signal 4 — the model is pulled (log-free, works everywhere).** A missing model is the single
cause of the silent-404 failure, so its presence is the strongest log-free evidence:
```bash
curl -s -m 5 http://127.0.0.1:11434/api/tags | head -c 200
```
```
{"models":[{"name":"mxbai-embed-large:latest","model":"mxbai-embed-large:latest","modified_at":"2026-07-14T09:54:36.3866
```
VERIFIED (re-checked live; ollama is up, daemon is down). Cross-check `modified_at` (local time)
against the first embedded row's `created_at` (**UTC** — mind the `+02:00` offset). If the vectors
begin right after the model landed, that is the cutover, and it closes the case.

**What this does NOT prove:** that vector *recall ranking* ran. `access_count` being non-zero on
61/64 rows proves recall ran *at all*, but text-search fallback bumps `access_count` identically —
it cannot distinguish vector from text ranking. Settling that needs `log_level = "debug"` + a live
daemon + one `memory_recall`. **Say "produced and stored, ranking unproven" rather than
overclaiming.**

---

## RESOLVED: why only 6 of 64 `memories` rows have an embedding

**The answer is NOT the config change. It is the missing ollama model.** The `[memory]`
`embedding_*` keys are a red herring — they landed *after* embeddings had already started working.

### The evidence

```bash
DB=/home/kyzdes/.openfang/data/openfang.db
sqlite3 -readonly $DB "SELECT COUNT(*), MIN(created_at), MAX(created_at) FROM memories WHERE embedding IS NOT NULL;"
sqlite3 -readonly $DB "SELECT COUNT(*), MIN(created_at), MAX(created_at) FROM memories WHERE embedding IS NULL;"
```
```
6|2026-07-14T07:57:59.046296592+00:00|2026-07-14T08:12:50.022249040+00:00
58|2026-07-13T19:33:53.818119584+00:00|2026-07-14T07:36:12.821467450+00:00
```
VERIFIED. **Zero overlap** — a clean temporal split, no interleaving:
```bash
sqlite3 -readonly $DB "SELECT COUNT(*) FROM memories WHERE embedding IS NULL     AND created_at > '2026-07-14T07:57';"   # -> 0
sqlite3 -readonly $DB "SELECT COUNT(*) FROM memories WHERE embedding IS NOT NULL AND created_at < '2026-07-14T07:57';"   # -> 0
```

The pre-change config proves no `[memory]` embedding config existed while ollama was being called:
```bash
grep -c 'embedding' /home/kyzdes/.openfang/config.toml.bak-embeddings    # -> 0
```
VERIFIED — the backup (mtime `09:54:57 +0200`) has `[memory]` with **only** `decay_rate = 0.05`.

Yet ollama was being POSTed every ~2 minutes since the night before:
```bash
sudo journalctl -u ollama --no-pager --since "2026-07-13" | grep -a '/v1/embeddings' | sed -n '1p;$p'
```
```
Jul 13 23:38:23 kyzdes ollama[125739]: [GIN] 2026/07/13 - 23:38:23 | 404 | 550.367µs | 127.0.0.1 | POST "/v1/embeddings"
Jul 14 11:54:40 kyzdes ollama[2819]:   [GIN] 2026/07/14 - 11:54:40 | 200 | 2.303359841s | 127.0.0.1 | POST "/v1/embeddings"
```
ollama started listening at `23:38:12` local; the **first POST arrived 11 seconds later**. Status
counts over the whole window:
```bash
for c in 200 404; do printf "%s: " $c; sudo journalctl -u ollama --no-pager --since "2026-07-13" \
  | grep -a '/v1/embeddings' | grep -ac "| $c |"; done
```
```
200: 34
404: 276
```

**Proof these were the daemon and not manual curls** — the seconds field of the 404s:
```bash
sudo journalctl -u ollama --no-pager --since "2026-07-13" | grep -a '/v1/embeddings' \
  | grep -a '| 404 |' | grep -oE ' - [0-9]{2}:[0-9]{2}:[0-9]{2} ' | grep -oE ':[0-9]{2} $' | sort | uniq -c | sort -rn | head -5
```
```
    145 :24
    118 :23
      2 :26
      2 :19
      2 :12
```
VERIFIED. **263 of 276 404s land on `:23`/`:24`** — a fixed machine cadence (two interleaved loops
phase-locked to daemon boot), impossible for hand-run curls. This is the `orchestrator`
`continuous = { check_interval_secs = 120 }` loop plus `ops`.

### The definitive timeline (all UTC)

| UTC | Event | Evidence |
|---|---|---|
| 07-13 21:38:12 | ollama starts listening | `msg="Listening on 127.0.0.1:11434"` |
| 07-13 21:38:23 | **first `POST /v1/embeddings` → 404** (11 s later, no config) | ollama journal |
| 21:38 → 07-14 07:37:24 | **276 × 404**, every ~2 min | ollama journal |
| 07-14 07:36:12.821 | **last memory row stored with `embedding = NULL`** | `MAX(created_at) WHERE embedding IS NULL` |
| 07-14 07:37:24 | last 404 | ollama journal |
| 07-14 07:38:18 | ollama restarts (PID 125739 → 2819); daemon down for the edit | ollama journal |
| 07-14 **07:54:36** | **`POST /api/pull` 200 (54.4 s) — `mxbai-embed-large` pulled** ← **the actual fix** | ollama journal |
| 07-14 07:54:48 | first `200` on `/v1/embeddings` (off-cadence `:48` → a manual test curl) | ollama journal |
| 07-14 07:54:57 | `config.toml` written with `embedding_provider`/`embedding_model` | `stat` mtime |
| 07-14 07:55:07 | daemon boot: `Embedding driver configured from memory config provider=ollama model=mxbai-embed-large` | daemon log |
| 07-14 **07:57:59.046** | **first memory row WITH an embedding** — ollama logs a `200` at the same second | both |
| 07-14 08:12:50.022 | last memory row written | DB |
| 07-14 08:36:41 | `OpenFang daemon stopped` | daemon log |

The `404` at `07:36:12` and the NULL row at `07:36:12.821` are **the same store attempt**. The `200`
at `07:57:59` and the first embedded row at `07:57:59.046` are **the same store attempt**.

### The mechanism (why NULL is permanent)

- Embeddings are computed **only at store time**, inline in the `memory_store` / episodic
  auto-capture path.
- On failure the binary logs `Embedding for remember failed: ` (and
  `Embedding for remember failed (streaming): `) and **stores the row anyway** with `embedding =
  NULL`. The store returns success. UPSTREAM/VERIFIED-by-strings:
  ```bash
  strings -n 8 /home/kyzdes/.openfang/bin/openfang | grep -iE 'embedding' | head -40
  ```
- **Unlike the chat path, the embedding path has no friendly 404 handler.** The chat path carries
  `Model not found on Ollama. Run `ollama pull <model>` first. Use /model to see options.` — the
  embedding path has **no equivalent**. This is exactly why 276 failures went unnoticed for 10 hours.
- Migration **v3 is a bare `ALTER TABLE`** — it adds the column and backfills nothing:
  ```
  ALTER TABLE memories ADD COLUMN embedding BLOB DEFAULT NULL
  INSERT OR IGNORE INTO migrations (version, applied_at, description) VALUES (3, datetime('now'), 'Add embedding column to memories')
  ```
- **There is no backfill / reindex / re-embed path for `memories` anywhere in the binary.**
  ```bash
  strings -n 6 /home/kyzdes/.openfang/bin/openfang | grep -iE 'backfill|reindex|re-embed' | head -20
  ```
  **This command returns ~11 hits, not 4 — expect the noise and ignore it.** The only hits that are
  **code paths** are these four, and they are the 0.6.8 workspace/state_dir split, unrelated to
  memory:
  ```
  Failed to backfill workspace: 
  *Failed to backfill state_dir (streaming): 
  *Failed to backfill workspace (streaming): 
  Failed to backfill state_dir: 
  ```
  VERIFIED. **Ignore these hits — they are not tools** (same pattern as the `memory_pool` /
  `memory_guard_size` noise under [Tool surface](#tool-surface)):
  - `- **Backfill Strategy**: Design DAGs with date-parameterized runs…` — **Airflow prose from a
    bundled skill's markdown**, compiled into the 66 MB binary.
  - `…create a new index with the correct mapping and reindex the data`, `- Use index aliases for
    zero-downtime reindexing…` — **Elasticsearch skill docs.** Same for the CI-image one.
  - `REINDEXEDESCAPEACHECKEY…` — the **SQLite keyword blob**, not a command.
  - `unable to identify the object to be reindexed` — SQLite's own error string.

  The binary bundles skill documentation as plain text, so **any `strings` grep for a generic
  English word will hit skill prose.** Match on code-shaped strings (a trailing `: `, a `crates/…`
  path, an SQL fragment), not on vocabulary. The only `OpenFang will rebuild embeddings` string
  lives in `crates/openfang-migrate/src/openclaw.rs` — the **OpenClaw import** path, not reachable
  for an existing DB. VERIFIED.

  **Conclusion is unchanged: there is no memory backfill path.** None of the noise is one.

### Is any action needed? **No — and backfilling would be actively wrong.**

```bash
sqlite3 -readonly $DB "SELECT CASE WHEN content LIKE '%[AUTONOMOUS TICK]%' THEN 'autonomous_tick'
  WHEN content LIKE '%[SCHEDULED TICK]%' THEN 'scheduled_tick' ELSE 'real_user' END k,
  COUNT(*) FROM memories GROUP BY k;"
```
```
autonomous_tick|54
scheduled_tick|8
real_user|2
```
VERIFIED. **62 of 64 (96.9%) of all episodic memory is tick pollution.** The 58 NULL rows are
almost entirely `User asked: [AUTONOMOUS TICK] You are running in continuous …` — embedding them
would spend ~1 s of ollama each to make *garbage* semantically retrievable, actively **degrading**
recall by crowding out the 2 real user memories. The correct remediation is **deletion of the
pollution and stopping the tick loop** (see below), not backfill. Since no backfill command exists,
the only way to embed old rows is hand-writing f32 BLOBs into the DB — **do not do this**;
it is a write to the user's production DB and buys nothing.

---

## Does recall use the embeddings?

**Partly, and the design is worse than "it ignores NULL rows."** The base recall SQL is a
**full-table scan with no `LIMIT` and no `agent_id` filter**:
```
SELECT id, agent_id, content, source, scope, confidence, metadata, created_at, accessed_at, access_count, embedding
FROM memories WHERE deleted = 0 ORDER BY accessed_at DESC, access_count DESC
```
VERIFIED via `strings -n 40 <bin> | grep -E 'FROM memories'`. Every recall loads **every
non-deleted row of every agent** into process memory and ranks in Rust. At 64 rows this is free; it
does not scale, and it is the shape that OOMs a small box.

Recall then hits one of two paths, both DEBUG-level strings in the binary:
- `Using vector recall (dims=` / `Using vector recall (streaming, dims=` / `Vector recall: `
- `Embedding recall failed, falling back to text search: ` (fallback fires when the **query**
  embedding fails, not when rows lack embeddings)

**NULL-embedding rows are still returned.** VERIFIED — they keep getting read *after* embeddings
were enabled:
```bash
sqlite3 -readonly $DB "SELECT (accessed_at=created_at) AS never_read, embedding IS NOT NULL AS emb, COUNT(*), MAX(access_count) FROM memories GROUP BY 1,2;"
```
```
0|0|55|182     <- 55 NULL-embedding rows HAVE been read; one 182 times
0|1|6|18       <- 6 embedded rows, max 18 reads
1|0|3|0        <- 3 rows never read
```
The most-read row (`access_count = 182`) has **no embedding** and was last read at
`2026-07-14T08:09:09Z` — well after the driver went live at `07:55:07Z`. So NULL rows are ranked
in alongside embedded ones (similarity 0 / recency fallback filling top-K), **diluting** vector
recall rather than being excluded. SUSPECT on the exact merge rule — the ranking code is stripped.
**What would settle it:** run the daemon with `log_level = "debug"`, issue one `memory_recall`, and
read the `Vector recall: ` line for the returned score/id set. Requires a live daemon; not done.

`Vector recall` never appears in the current daemon log:
```bash
grep -aiE 'Vector recall|falling back to text search' /home/kyzdes/.openfang/daemon-start.log   # -> no output
```
This is **not** evidence recall never ran — `log_level` is unset in `config.toml` (default INFO)
and those strings are DEBUG. The `access_count` values above prove recall *did* run. Do not
conclude "recall is broken" from the absent log line.

Access bookkeeping on read: `UPDATE memories SET access_count = access_count + 1, accessed_at = ?1 WHERE id = ?2`.

---

## `[memory]` config keys

Live config (VERIFIED, `grep -n -A15 '^\[memory\]' /home/kyzdes/.openfang/config.toml`):
```toml
[memory]
decay_rate = 0.05
embedding_model = "mxbai-embed-large"
embedding_provider = "ollama"
```

**`[memory]` is read ONCE at boot — there is no hot reload.** The embedding driver binds during
startup and never re-reads config: the log carries exactly **one** `Embedding driver configured
from memory config` line, at `07:55:07`, at daemon boot. **Editing `[memory]` on a running daemon
changes nothing until you restart it** — stop first, per
[the enable procedure](#enable-embeddings-from-scratch-the-ordered-procedure). VERIFIED (single
occurrence in the daemon log, at startup).

Full key set compiled into the binary (VERIFIED via `strings`; unset ones use defaults):

| Key | Notes |
|---|---|
| `decay_rate` | applied as `UPDATE memories SET confidence = MAX(0.1, confidence * ?1)` — **floored at 0.1**, never reaches 0. VERIFIED (string). |
| `embedding_provider` | `ollama` is the **one path that works**. See #1212 below. |
| `embedding_model` | must be **already pulled** — an unpulled model is a silent 404 storm. |
| `embedding_api_key_env` | not needed for ollama. |
| `session_ttl_hours` | |
| `consolidation_interval_hours` | default **24** — VERIFIED: log line `Memory consolidation scheduled every 24 hour(s)` at `07:55:07.407189Z`. |
| `consolidation_threshold` | `crates/openfang-memory/src/consolidation.rs`; failure string `Memory consolidation failed: `. |
| `backend` | selects the **HTTP memory backend** (see below). Default = sqlite. |
| `sqlite_path` | |
| `vector_dims` | exposed in the dashboard as `Vector Dimensions`. See #1251 — the value comes from a **hard-coded model→dims table**, *not* from the response. |

**`confidence` is inert at store time.** The INSERT hard-codes it:
```
INSERT INTO memories (id, agent_id, content, source, scope, confidence, metadata, created_at, accessed_at, access_count, deleted, embedding)
VALUES (?1, ?2, ?3, ?4, ?5, 1.0, ?6, ?7, ?7, 0, 0, ?8)
```
VERIFIED — `confidence` is the literal `1.0`, not a bind parameter; `accessed_at` is bound to
`?7` (= `created_at`). Confirmed in data: every row is `confidence = 1.0`. Any `confidence` a tool
passes to `memory_store` is **discarded**. Only the decay job ever moves it.

### Embedding driver selection order (VERIFIED by strings + behaviour)

1. **Explicit `[memory] embedding_provider`** → `Embedding driver configured from memory config`.
2. **Auto-detect** → probes `localhost:11434`; logs `Embedding driver auto-detected: ` /
   `Embedding driver auto-detected via ` / `Local embedding provider `. **This runs with no config
   at all** — proven by the 276 pre-config 404s above.
3. **Cloud env-key scan**, else the give-up message:
   > `No embedding provider available. Memory recall will use text search only. Configure [memory] embedding_provider in config.toml or set an API key (OPENAI_API_KEY, GROQ_API_KEY, MISTRAL_API_KEY, TOGETHER_API_KEY, FIREWORKS_API_KEY, COHERE_API_KEY).`

**Privacy trap:** if auto-detect picks a cloud provider, the binary warns
`Embedding driver configured to send data to external API ` … ` text content will leave this
machine`. On a box with `OPENAI_API_KEY` in the environment and no local ollama, **every memory you
store is silently POSTed to OpenAI.** This is the core of #1212. Here it is moot — ollama wins.

`Default model when nothing is set: text-embedding-3-small` (VERIFIED, string).

---

## Storage format

`4096`-byte BLOB = **1024 × f32** (`mxbai-embed-large` = 1024 dims). VERIFIED:
```bash
sqlite3 -readonly $DB "SELECT id, length(embedding), scope, source, substr(content,1,60) FROM memories WHERE embedding IS NOT NULL LIMIT 3;"
```
```
aef1e719-232f-479c-bf79-fa4310e14204|4096|episodic|"conversation"|User asked: [AUTONOMOUS TICK] You are running in continuous
```
`mxbai-embed-large` **is** in the compiled dims table (alongside `text-embedding-3*`,
`all-MiniLM-L6-v2`, `all-MiniLM-L12-v2`, `nomic-embed-text`, `nomic-ai/nomic-embed-text-v1.5`,
`embed-english-v3.0`, `togethercomputer/m2-bert-80M-8k-retrieval`, `mistral-embed`), so dims are
correct here. A model **outside** that table gets a wrong `dims` (#1251) — cosmetic today because
storage is variable-length and recall compares actual returned length.

No vector index exists — **no `sqlite-vss` / `vec0` virtual table**, no `idx_memories_*` on
`embedding`. Only:
```
CREATE INDEX idx_memories_agent ON memories(agent_id);
CREATE INDEX idx_memories_scope ON memories(scope);
```
Similarity is a brute-force scan in Rust over every loaded row. VERIFIED (`.schema memories`).

---

## Schema & live state (VERIFIED)

```sql
CREATE TABLE memories (
  id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, content TEXT NOT NULL,
  source TEXT NOT NULL, scope TEXT NOT NULL DEFAULT 'episodic',
  confidence REAL NOT NULL DEFAULT 1.0, metadata TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL, accessed_at TEXT NOT NULL,
  access_count INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0
, embedding BLOB DEFAULT NULL);
```
Note `deleted` — **recall filters `deleted = 0`; deletes are soft.** Rows are never reclaimed.

```bash
sqlite3 -readonly $DB "SELECT m.agent_id, a.name, COUNT(*), SUM(embedding IS NOT NULL) FROM memories m LEFT JOIN agents a ON a.id=m.agent_id GROUP BY m.agent_id;"
```
```
91c689c2-17e3-4763-b360-65aea020cc57|orchestrator  |54|6
cbbfb77e-14f4-4c44-8c1a-7260986900c9|ops           | 7|0
b09ea7eb-fb30-442f-934c-1a4049cdec16|assistant     | 2|0
c08fae4f-6c67-4733-a6ea-3610bdeecde0|health-tracker| 1|0
```
**Only 4 of 30 agents have ever stored a memory** — exactly the 4 scheduled ones. Memory here is a
byproduct of the scheduler, not of use.

- `scope`: **100% `episodic`** — and that is the only value the binary can produce. This is **not**
  a feature waiting to be switched on; see
  [the "semantic memory" decoy](#first-semantic-memory--embeddings--vector-recall-there-is-no-scope-toggle).
- `metadata`: **100% `{}`**. Nothing populates it.
- `entities = 0`, `relations = 0` — **the `knowledge_*` tools have never been used.** The knowledge
  graph is fully unexercised on this install; treat `knowledge_add_entity` /
  `knowledge_add_relation` / `knowledge_query` as UNVERIFIED.

---

## TRAP: `memories.source` is double-encoded

```bash
sqlite3 -readonly $DB "SELECT COUNT(*) FROM memories WHERE source='conversation';"      # -> 0     WRONG
sqlite3 -readonly $DB "SELECT COUNT(*) FROM memories WHERE source='\"conversation\"';"  # -> 64    RIGHT
sqlite3 -readonly $DB "SELECT DISTINCT hex(source) FROM memories;"                      # -> 22636F6E766572736174696F6E22
```
VERIFIED. `0x22` = `"`. The value is `serde_json::to_string`'d **then** bound to a `TEXT` column —
the JSON string literal (quotes included) is what lands in SQLite. The column is declared
`TEXT NOT NULL`, so nothing rejects it.

Same bug class: `agents.state` stores `"suspended"`. Assume **every enum-ish TEXT column written
through serde is double-encoded** and probe with `hex()` before writing a `WHERE`.

Robust predicates that survive a future fix:
```sql
WHERE TRIM(source, '"') = 'conversation'
WHERE source LIKE '%conversation%'
```

`scope` is **NOT** affected (`episodic`, unquoted) — it is written as a plain string. **Do not
assume; check each column.**

---

## TRAP: `[AUTONOMOUS TICK]` episodic-memory pollution

```bash
sqlite3 -readonly $DB "SELECT substr(content,1,45), COUNT(*) FROM memories GROUP BY substr(content,1,45);"
```
```
User asked: [AUTONOMOUS TICK] You are running|54
User asked: [SCHEDULED TICK] You are running |8
User asked: [From: Slava Kuznetsov (tg_id:839|2
```
VERIFIED. **Every scheduler tick that reaches the LLM is auto-captured as an episodic memory**,
prefixed `User asked: `. The tick prompt is synthetic — the agent never spoke to a user — yet it is
persisted as `source="conversation"`, `scope=episodic`, indistinguishable from real dialogue.

Compounding factors, all VERIFIED elsewhere in this install:
- `orchestrator` runs `continuous = { check_interval_secs = 120 }` → **720 ticks/day**.
- `ops` ships `periodic = { cron = "every 5m" }` (upstream #1206) → **288/day**.
- Each tick concludes "No actionable items" and stores that as a memory.

Consequences:
1. **Recall is poisoned.** The 2 real user memories compete against 62 near-identical tick rows.
   Because the base query orders by `accessed_at DESC, access_count DESC` and NULL rows still rank,
   the ticks *win* — the top row has `access_count = 182`.
2. **Embedding cost is wasted.** Every embedded row here (6/6) is tick text. Each costs ~0.8–1.3 s
   of ollama.
3. **Unbounded growth.** ~1000 rows/day of self-generated text, each re-read by every full-table
   recall scan, forever (`deleted` is soft).

**Fix the source, not the symptom** — removing the schedules stops the inflow (`[schedule]` in
`agents/ops/agent.toml`, `agents/orchestrator/agent.toml`). That is a **write to the production
install and is out of scope for a read-only session** — report it, do not do it.

Diagnostic to quantify on any install:
```bash
sqlite3 -readonly $DB "SELECT COUNT(*) FROM memories WHERE content LIKE '%TICK]%';"
```

---

## Tool surface

VERIFIED present (`strings -n 6 <bin> | grep -oE '\b(memory|knowledge)_[a-z_]+\b' | sort -u`):

| Tool | Status |
|---|---|
| `memory_store` | writes `memories`; embeds inline; `confidence` arg discarded |
| `memory_recall` | full-table load → vector-or-text rank; bumps `access_count` |
| `memory_update` | UNVERIFIED — no schema recovered, never invoked here |
| `knowledge_add_entity` / `knowledge_add_relation` / `knowledge_query` | UNVERIFIED — `entities`/`relations` are empty |

Ignore these `strings` hits — they are **not** tools: `memory_read` / `memory_write` (booleans in
`[capabilities]`), `memory_pool` / `memory_guard_size` / `memory_reservation*` / `memory_may_move`
(wasmtime internals), `memory_key_pattern` / `memory_image` (unrelated).

The default bundled tool grant is 8 tools and includes both:
```
tool_names=["file_r… , "memory_store", "memory_recall", …]
```
VERIFIED from `Tools selected for LLM request agent=orchestrator … tool_count=8`.

---

## The `openfang memory` CLI is the KV store — NOT `memories`

```bash
openfang memory --help
```
```
Search and manage agent memory (KV store) [*]
Commands:
  list    List KV pairs for an agent
  get     Get a specific KV value
  set     Set a KV value
  delete  Delete a KV pair
```
VERIFIED. It maps to `kv_store`, a completely separate table. **`set`/`delete` are WRITES —
forbidden in a read-only session.**

All subcommands require a live daemon (VERIFIED, daemon is down here):
```
✘ `openfang memory list` requires a running daemon
  fix: Start the daemon: openfang start
hint: Or try `openfang chat` which works without a daemon
```
Read it from SQLite instead:
```bash
sqlite3 -readonly $DB "SELECT agent_id, key, value, version FROM kv_store LIMIT 10;"
```
```
00000000-0000-0000-0000-000000000001|__openfang_schedules_migrated_v1|true|1
b09ea7eb-fb30-442f-934c-1a4049cdec16|delivery.last_channel|{"channel":"telegram","recipient":"83979215"}|2
00000000-0000-0000-0000-000000000001|user_name|"No value found for key 'user_name'"|1
00000000-0000-0000-0000-000000000001|first_interaction|"2026-07-14"|1
00000000-0000-0000-0000-000000000001|user_preferences|"{}"|1
```
Schema: `kv_store(agent_id, key, value BLOB, version, updated_at)`, PK `(agent_id, key)`, upsert
`ON CONFLICT(agent_id, key) DO UPDATE SET value = ?3, version = version + 1, updated_at = ?4`.

**TRAP — the agent stored an error message as a value.**
`user_name = "No value found for key 'user_name'"`. An agent called `memory_get`, got the
*not-found error string* back as if it were data, and wrote it straight back with `memory_set`.
The KV get path returns errors **in-band as a plain string**, indistinguishable from a real value.
VERIFIED. **Never trust a KV read that looks like prose** — check for the literal prefix
`No value found for key`. `user_preferences = "{}"` is the same double-encoding as `source`
(a JSON string containing `{}`, not an object).

`delivery.last_channel` is operationally critical and undocumented: it is how cron
`last_channel` delivery resolves its destination. Note it is keyed to the **`assistant`** agent id.

---

## The compactor

Rolling summarization writes to `canonical_sessions`:
```sql
CREATE TABLE canonical_sessions (
  agent_id TEXT PRIMARY KEY, messages BLOB NOT NULL,
  compaction_cursor INTEGER NOT NULL DEFAULT 0, compacted_summary TEXT, updated_at TEXT NOT NULL);
```
Upsert: `ON CONFLICT(agent_id) DO UPDATE SET messages = ?2, compaction_cursor = ?3, compacted_summary = ?4, updated_at = ?5`.

Live sequence (VERIFIED, `grep -aiE 'compact' /home/kyzdes/.openfang/daemon-start.log`):
```
08:11:07.921 INFO openfang_kernel::kernel   : Pre-emptive compaction before LLM call agent_id=91c689c2… messages=34 estimated_tokens=1308
08:11:07.922 INFO openfang_runtime::compactor: Compacting session messages total=34 compacting=23 keeping=11
08:11:38.555 INFO openfang_runtime::compactor: Session compaction complete (single-pass) summary_len=485 compacted=23
08:11:38.575 INFO openfang_kernel::kernel   : Compacted 23 messages into summary (485 chars), kept 11 recent messages. Post-audit: clean.
```
It fires **pre-emptively before an LLM call**, keeps a recent tail (11 of 34), is `single-pass`, and
self-checks (`Post-audit: clean`). It burned **31 seconds** (`08:11:07.922` → `08:11:38.555`) — a
full LLM round-trip **inline on the request path**, at only 1308 estimated tokens.

**TRAP — `compaction_cursor` is a dead column.** It is `0` for every row, *including* the
orchestrator that demonstrably compacted 23 messages:
```bash
sqlite3 -readonly $DB "SELECT agent_id, compaction_cursor, length(compacted_summary), length(messages) FROM canonical_sessions;"
```
```
91c689c2-17e3-4763-b360-65aea020cc57|0|485|3032
cbbfb77e-14f4-4c44-8c1a-7260986900c9|0||6369
b09ea7eb-fb30-442f-934c-1a4049cdec16|0||25129
c08fae4f-6c67-4733-a6ea-3610bdeecde0|0||2492
```
VERIFIED. It is bound (`?3`) but always written as `0`, because `single-pass` compaction **rewrites
`messages` in place** rather than advancing a cursor over an append-only log. **Do not use
`compaction_cursor` to detect whether compaction ran** — use `compacted_summary IS NOT NULL`.
Only the orchestrator (`length=485`) has ever been compacted; `assistant` carries 25129 bytes of
uncompacted messages.

Related user-facing strings: `Context usage is healthy.` · `Consider using /compact if the
conversation grows longer.` · `Context is getting full. Use /compact to summarize older messages.`
· `Context is nearly full! Use /compact or /new immediately.` · `Context is full. Try /compact or
/new.`

---

## The HTTP memory backend (`[memory] backend`)

An entire alternative backend exists: `crates/openfang-memory/src/http_client.rs`
(`openfang-memory/0.4` UA). VERIFIED by strings; **UNVERIFIED behaviourally** — unused here
(`backend` unset → sqlite).

```
memory-api health check passed
Stored memory via HTTP backend        | HTTP memory store failed, falling back to SQLite
Searched memories via HTTP            | HTTP memory search failed, falling back to SQLite
Recalled memories via HTTP backend
```
Its wire format is camelCase (`agentId`, `score`, `importance`, `deduplicated`) — note `importance`
and `deduplicated` have **no SQLite equivalent**, so the two backends are not feature-equal.
It **silently falls back to SQLite** on any failure, so a misconfigured `memory-api` looks healthy
while writing locally.

---

## Upstream (both OPEN; repo abandoned since 2026-05-12 = v0.6.9 = this build)

**#1212 — "Embedding driver hard-codes 6 cloud providers; OpenAI-compatible base_url override
ignored (regression from #395 / #212 path for non-Ollama)"** — OPEN. Body confirms the hard-coded
key allowlist quoted above and states: *"chat routing works fine to local providers (Ollama, vLLM
via OLLAMA_HOST / VLLM_HOST), but embedding-recall still goes to OpenAI cloud, leaking
text-content."* **The title's "for non-Ollama" is the load-bearing part: `provider = "ollama"` is
the one embedding path that works.** #395 (*"Embedding provider URL configuration not working for
Ollama"*) is CLOSED/fixed; #212 CLOSED without fixing the embedding side. **This install is on the
one good path — do not "improve" it to `openai` + `base_url`.**

**#1251 — "Embedding driver: support OpenAI-compatible servers with non-/v1 base paths and
non-table embedding dimensions"** — OPEN. Quotes `crates/openfang-runtime/src/embedding.rs` ~L208:
```rust
let needs_v1 = matches!(provider,
    "openai" | "groq" | "together" | "fireworks" | "mistral" | "ollama" | "vllm" | "lmstudio");
if needs_v1 && !trimmed.ends_with("/v1") { format!("{trimmed}/v1") } else { trimmed.to_string() }
```
So **`ollama` is a first-class recognized embedding provider** and `/v1` is auto-appended — which is
exactly why this install's ollama receives `POST /v1/embeddings`. Consequences: a `base_url` of
`http://h:8004/v3` becomes `http://h:8004/v3/v1` (broken); no non-`/v1` server is reachable without
a rewriting proxy. Part 2: `dims` come from a **hard-coded model-name table**, not the response;
the reporter notes it is *"mostly cosmetic"* since storage is variable-length. Suggested (unmerged)
key: `[memory] embedding_dimensions`. **`embedding_dimensions` does NOT exist in v0.6.9 — the
compiled key is `vector_dims`. Do not copy config from the issue.**

Both are OPEN with **no maintainer response**; upstream is dead. Any fix means the
[librefang](https://github.com/librefang/librefang) fork or a local patch.

---

## Operator checklist

**Turning embeddings on** → ⚠️ **FIRST check whether they already are** — on this install they are,
and the answer is *do nothing*. Run Signals 1/2/4 ([the four-signal
proxy](#how-to-prove-embeddings-are-live-without-starting-the-daemon)); if vectors exist at the right
width, **STOP — change nothing, do not stop the daemon.** Only if they have never once succeeded go
to [Enable embeddings from scratch](#enable-embeddings-from-scratch-the-ordered-procedure) (pull the
model FIRST). That procedure opens with `stop`; routing to it unconditionally means taking down a
production daemon to perform a no-op.
**Proving they work** → [the four-signal proxy](#how-to-prove-embeddings-are-live-without-starting-the-daemon).

**Verify the embedding path is actually live (the config alone proves nothing):**
```bash
curl -s -m 5 http://127.0.0.1:11434/api/tags | head -c 200        # is the model PULLED?
sudo journalctl -u ollama --no-pager -n 200 | grep -a '/v1/embeddings' | tail -5   # 200 or 404?
```
A wall of `404` = the model is missing → **every memory stored in that window is permanently
NULL-embedded.** `openfang doctor` does **not** check this. UNVERIFIED that any built-in check does.
The `journalctl` line needs **root** and a systemd ollama — if you have neither, use Signals 1/2/4,
which need no logs.

**Before writing any `WHERE` on a TEXT column, probe its real bytes** (`source` is double-encoded,
`scope` is not — [see the trap](#trap-memoriessource-is-double-encoded)):
```bash
sqlite3 -readonly $DB "SELECT DISTINCT hex(source), hex(scope) FROM memories;"
```
```
22636F6E766572736174696F6E22|657069736F646963
```
Leading/trailing `22` (`"`) = double-encoded → use `TRIM(col,'"')`.

**Never do these:**
- Trust `[memory] embedding_provider` as evidence embeddings work — auto-detect and a missing model
  both defeat it. **Check the ollama journal.**
- Write `WHERE source='conversation'` — use `TRIM(source,'"')`.
- Use `openfang memory list` to inspect episodic memories — wrong table.
- Read `compaction_cursor` to detect compaction — always `0`.
- Look for a backfill command — **there is none**; stop searching and say so. Its own `strings`
  grep returns ~11 hits of **bundled skill prose** — none is a tool.
- Hunt for a way to enable `scope='semantic'` — **the binary cannot produce that value.**
  "Semantic memory" means embeddings.
- Hand-write embedding BLOBs into the production DB.
- Reason from a remembered WAL size — `ls` it; reading the DB checkpoints it away.
- "Fix" the 58 NULL rows. They are an **expected** historical artifact of a solved problem, and
  96.9% of them are tick garbage. Backfilling degrades recall.
- `SELECT * FROM memories` without a `LIMIT` — the `content` column holds full turn text.

**Safe read-only one-liner for a full memory health snapshot:**
```bash
DB=/home/kyzdes/.openfang/data/openfang.db
sqlite3 -readonly $DB "SELECT COUNT(*) total, SUM(embedding IS NOT NULL) embedded,
  SUM(content LIKE '%TICK]%') tick_pollution, COUNT(DISTINCT agent_id) agents,
  (SELECT COUNT(*) FROM entities) entities, (SELECT COUNT(*) FROM kv_store) kv FROM memories WHERE deleted=0;"
```
```
64|6|62|4|0|5
```

**WAL caveat — the rule is conditional; do not trust any `ls` snapshot of it, including this one.**
The DB is in WAL mode, so `-wal`/`-shm` **appear, grow, empty and vanish** depending on who has the
DB open. Any figure written down here is stale by the time you read it. **Check, then decide:**
```bash
ls -la /home/kyzdes/.openfang/data/
```
```
-rw-r--r-- 1 kyzdes kyzdes 995328 Jul 14 13:57 openfang.db
-rw-r--r-- 1 kyzdes kyzdes  32768 Jul 14 15:05 openfang.db-shm
-rw-r--r-- 1 kyzdes kyzdes      0 Jul 14 15:05 openfang.db-wal
```
- **`-wal` non-empty** → it holds committed data **not yet in `.db`**. Copying `openfang.db` alone
  yields a **stale snapshot**. Copy `.db`, `-wal` and `-shm` **together**, or don't copy at all.
- **`-wal` absent or 0 bytes** → checkpointed; `.db` is current. (Above: 0 bytes.)

**This claim is self-invalidating — reading the DB changes it.** The last connection to close
checkpoints the WAL and unlinks it, so *following this playbook with `sqlite3` empties the very WAL
it describes*. An earlier revision recorded "WAL is 733 KB with no checkpoint"; that was true when
written and is now false. **Never reason from a remembered WAL size — always `ls` first.**

**The advice that does not go stale: read via `sqlite3` against the live path** (as every command
here does). That is correct in every WAL state and is why none of this matters for read-only work —
it only matters if you **copy** the file.

**Permissions:** `openfang.db` is `0644` (world-readable) and `memories.content` holds full
conversation text. On a multi-user box this is a disclosure. `config.toml`/`secrets.env` are `0600`.
