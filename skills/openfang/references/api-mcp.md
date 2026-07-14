# OpenFang HTTP API & MCP (v0.6.9)

**Read this when** the task touches: the daemon's HTTP API on `127.0.0.1:4200`, the WebChat UI, the
WebSocket endpoint, auth/exposure of the API, the 65 built-in agent tools, or mounting OpenFang
itself as an MCP server (`openfang mcp`) inside another client.

**Provenance note.** Endpoint status codes below were observed while the daemon was UP earlier in
this session and are marked VERIFIED. Route names not exercised by a request were recovered from
`strings` on the binary and are marked UPSTREAM-BINARY (present in the executable, behaviour not
confirmed). The daemon is DOWN at the time of writing — re-verify before relying on a `200`.

---

## ⛔ The one that costs the most: never run `openfang mcp` from a tool call

**`openfang mcp` is a stdio server. It does not exit.** It reads JSON-RPC from stdin and writes to
stdout forever.

Running it from an agent's Bash tool call is the same class of trap as `openfang start` running in
the foreground — but worse, because the tool captures its stdout into the **agent host process's
memory**. The buffer grows without bound.

**Evidence (VERIFIED, this machine, 2026-07-14):** an agent researching this very document ran
`openfang mcp` against a sandboxed `OPENFANG_HOME`. The host process went from 525 MB to 4.27 GB in
under three minutes. Stopping the workflow did **not** kill the orphaned server; the process kept
growing and was OOM-killed five minutes later at **12.3 GB**, taking the terminal with it:

```
13:27:46 kernel: Out of memory: Killed process 207873 (2.1.209)
                 total-vm:14941864kB, anon-rss:12271636kB
         systemd: app-gnome-Alacritty-38840.scope: Failed with result 'oom-kill'
```

**Rule.** Treat these four as never-run-from-a-tool-call:

| Command | Why |
|---|---|
| `openfang mcp` | stdio server, never exits, output buffers into your memory |
| `openfang start` | runs in the FOREGROUND (and dies on SIGPIPE if piped to `head`) |
| `openfang tui` | full-screen interactive terminal UI |
| `openfang dashboard` | opens a browser and blocks |

To learn what `openfang mcp` exposes, read the source or the binary — do not execute it.
To *use* it, wire it into a client config (below); the client owns its lifetime, not you.

---

## Mounting OpenFang as an MCP server

`openfang mcp --help` (VERIFIED — `--help` is intercepted by the arg parser and exits immediately
without starting the server):

```
Start MCP (Model Context Protocol) server over stdio

Usage: openfang mcp [OPTIONS]

Options:
      --config <CONFIG>  Path to config file
  -h, --help             Print help
```

**Prefer the zero-risk confirmation.** You do not have to trust that `--help` short-circuits — both
strings are recoverable from the binary, with no process to run away from you (VERIFIED,
2026-07-14):

```bash
strings -n 8 /home/kyzdes/.openfang/bin/openfang \
  | grep -F 'Start MCP (Model Context Protocol) server over stdio' | head -1
```

Note the bounded form: **`strings` on this 66 MB binary is 300k+ lines — never run it bare.**
Always `| grep … | head`.

Claude Code plugin config — `.mcp.json` in the plugin root:

```json
{
  "mcpServers": {
    "openfang": {
      "command": "/home/kyzdes/.openfang/bin/openfang",
      "args": ["mcp"]
    }
  }
}
```

**UNVERIFIED:** the exact tool list this server advertises. Determining it requires an
`initialize` + `tools/list` handshake, i.e. actually running the server — see the warning above.
Let the MCP client perform that handshake and read the tool list from the client, then record it
here. Do not hand-run the handshake from a Bash call.

**SUSPECT — leaning "does not require a running daemon".** The question is whether `openfang mcp`
needs the daemon or boots its own in-process kernel like several other CLI commands do (see
`cli-reference.md`). The OOM incident settles half of it: **the daemon was already down when it
ran.** Timeline (VERIFIED):

```bash
stat -c '%y' ~/.openfang/daemon-start.log            # 2026-07-14 10:36:41  (local)
sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log | grep -F SIGTERM | tail -1
#   2026-07-14T08:36:41.334925Z  Received SIGTERM   → local is UTC+2, so the daemon died 10:36 local
```

The OOM was at **13:27:46 local — ~3 hours after the daemon stopped.** So `openfang mcp` did **not**
fail fast with "daemon not running"; it ran, allocated 12.3 GB, and had to be killed. It therefore
does not *require* a live daemon.

What that does **not** prove: whether the growth *was* an ephemeral kernel booting, or an error loop
spinning against a dead socket. **What settles it:** watch `audit_entries` — an ephemeral kernel
writes ~9 rows on boot (the `openfang status` signature). If the row count is unchanged across an
`mcp` run, it never booted a kernel. Do not run it to find out; let a real MCP client own the
process and check the table afterward.

---

## Auth model

`GET /api/security` reported (VERIFIED, daemon up):

```json
"auth": {"api_key_set": false, "mode": "localhost_only"}
```

Three accepted credentials (UPSTREAM-BINARY, from the WS rejection string):

> `WebSocket upgrade rejected: no valid Bearer token, ?token=, or openfang_session cookie`

- `Authorization: Bearer <key>` — the key is `api_key` in `config.toml` or `OPENFANG_API_KEY`
- `?token=<key>` query parameter
- `openfang_session` cookie (this is what the WebChat UI uses for the WS upgrade)

**Current posture on this install:** no API key is set, and the listener is bound to
`127.0.0.1:4200`, so the API is unauthenticated but reachable only from loopback. That is fine as
long as the bind address never changes.

### 🚨 DANGER — the two-line path to a fully open agent OS

```toml
api_listen = "0.0.0.0:4200"     # config.toml comment suggests this "for Docker"
```
```bash
OPENFANG_ALLOW_NO_AUTH=1        # explicitly disables auth
```

Either alone is survivable; together they expose an API that can `shell_exec` on your box to the
network. Without a key, non-loopback requests are rejected with 401 (since 0.5.10) — the
`OPENFANG_ALLOW_NO_AUTH=1` escape hatch removes that last guard. The binary's own warning
(UPSTREAM-BINARY):

> `Non-loopback requests will be rejected with 401. Set OPENFANG_API_KEY (or api_key in config.toml),
> or bind to 127.0.0.1, or set OPENFANG_ALLOW_NO_AUTH=1 to explicitly run open.`

**Never set both.** If the API must leave loopback, set `api_key` first.

---

## ⚠️ The trailing-slash trap

**VERIFIED (daemon up):** the non-slash form returns 200; the slash form returns **404**.

```
GET /api/agents    → 200
GET /api/agents/   → 404
```

Same for `/api/skills/`, `/api/hands/`, `/api/workflows/`, `/api/cron/jobs/`.

The perverse part: **the slash forms are the literals embedded in the binary.** Anything you script
by grepping route strings out of the executable will 404. Always drop the trailing slash.

---

## Routes

### Verified with a real GET (daemon up, all 200)

| Endpoint | What it gives you |
|---|---|
| `/api/status` | kernel state + full agent list |
| `/api/health` | liveness |
| `/api/health/detail` | the useful one — see below |
| `/api/agents` | agents with ids/names/state |
| `/api/models`, `/api/models/aliases`, `/api/providers` | model catalog and provider list |
| `/api/channels` | full channel catalog **with field schemas** — the truth about channels |
| `/api/tools` | all 65 tools with JSON Schema |
| `/api/skills` | user skills only — returns `{"skills":[],"total":0}`, see `automation.md` |
| `/api/hands`, `/api/hands/active` | bundled hands and active instances |
| `/api/workflows`, `/api/cron/jobs`, `/api/triggers` | automation state |
| `/api/sessions` | conversation sessions |
| `/api/usage`, `/api/usage/summary`, `/api/usage/by-model` | token/cost accounting |
| `/api/budget` | budget limits (all `0.0` here — see `models-providers.md`) |
| `/api/security` | 15-feature security posture + auth mode |
| `/api/audit/recent`, `/api/audit/verify` | Merkle audit trail (`/api/audit` alone → 404) |
| `/api/config` | effective config |
| `/api/approvals` | pending tool-call approvals |
| `/api/mcp/servers` | MCP servers registered *into* OpenFang |
| `/api/peers` | OFP mesh peers (`{"peers":[],"total":0}` — mesh disabled) |
| `/api/comms/topology` | inter-agent comms graph |
| `/api/integrations`, `/api/integrations/available` | 25 integration templates |

`/api/health/detail` is the best single probe (VERIFIED, real response):

```json
{"agent_count":30,"config_warnings":[],"database":"connected","panic_count":0,
 "restart_count":0,"status":"ok","uptime_seconds":393,"version":"0.6.9"}
```

When the daemon is DOWN, the same request gives you `000` from curl:

```bash
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4200/api/status   # → 000 = daemon down
```

### Agent-scoped routes (UPSTREAM-BINARY — recovered from strings, not exercised)

Base: `/api/agents/{id}/…`

`ws` · `message` · `history` · `session` · `sessions` · `model` · `mode` · `config` · `identity` ·
`tools` · `skills` · `files` · `deliveries` · `mcp_servers` · `start` · `stop` · `restart` ·
`activate` · `clone` · `uninstall`

`{id}` is a **UUID**, not a name (the same UUID-vs-name inconsistency documented in
`cli-reference.md`).

### Other routes (UPSTREAM-BINARY)

`/api/shutdown` · `/api/config/set` · `/api/logs/stream` · `/api/uploads/` · `/api/comms/send` ·
`/api/comms/task` · `/api/a2a` · `/api/event` · `/api/skills/reload` · `/api/skills/install` ·
`/api/skills/uninstall` · `/api/clawhub/install` · `/api/marketplace` · `/api/hands/install` ·
`/api/hands/instances/` · `/api/integrations/add` · `/api/integrations/health` ·
`/api/integrations/reload` · `/api/memory/agents/` · `/api/budget/agent` · `/api/auth/logout` ·
`/api/pairing/request` · `/api/pairing/devices/`

**Do not confuse these with third-party paths in the same string table.** `/api/v1/chat.sendMessage`,
`/api/v1/me`, `/api/v4/posts`, `/api/v4/websocket`, `/api/v1/streaming/user` are **outbound** calls
the channel adapters make to Mattermost/Mastodon/Zulip. They are not OpenFang server routes.

---

## WebChat UI and WebSocket

- WebChat UI at `/` — Alpine.js + Tailwind, served inline from the binary (VERIFIED: the boot log
  prints `WebChat UI available at http://127.0.0.1:4200/`).
- WebSocket at `/api/agents/{id}/ws` (VERIFIED from the same boot log line:
  `WebSocket endpoint: ws://127.0.0.1:4200/api/agents/{id}/ws`).

Limits, from `GET /api/security` (VERIFIED):

| Limit | Value |
|---|---|
| Rate limiter | GCRA, **500 tokens/min** |
| WS max message | **65 536 B** |
| WS messages | **10/min** |
| WS connections | **5 per IP** |
| WS idle timeout | **1800 s** |
| WASM fuel | 1 000 000, 30 s timeout |

---

## The 65 agent tools

From `GET /api/tools` (VERIFIED — each ships a JSON Schema). These are what an *agent* can call, not
HTTP routes.

| Family | Tools |
|---|---|
| Files | `file_read` `file_write` `file_list` `create_directory` `apply_patch` |
| Web | `web_fetch` `web_search` |
| Shell / process | `shell_exec` `docker_exec` `process_start` `process_write` `process_poll` `process_kill` `process_list` |
| Memory / KG | `memory_store` `memory_recall` `knowledge_add_entity` `knowledge_add_relation` `knowledge_query` |
| Agents | `agent_spawn` `agent_list` `agent_find` `agent_kill` `agent_send` `agent_activate` |
| Tasks | `task_post` `task_claim` `task_complete` `task_list` |
| Events | `event_publish` |
| A2A | `a2a_discover` `a2a_send` |
| Browser | `browser_navigate` `browser_click` `browser_type` `browser_read_page` `browser_screenshot` `browser_scroll` `browser_back` `browser_wait` `browser_run_js` `browser_close` |
| Media | `image_analyze` `image_generate` `media_describe` `media_transcribe` `speech_to_text` `text_to_speech` |
| Skills | `skill_list` `skill_describe` `skill_execute` |
| Hands | `hand_list` `hand_activate` `hand_deactivate` `hand_status` |
| Schedule | `schedule_create` `schedule_delete` `schedule_list` `cron_create` `cron_list` `cron_cancel` |
| Channels | `channel_send` |
| Misc | `canvas_present` `location_get` `system_time` |

Notes worth knowing:
- `web_fetch` does GET/POST/PUT/PATCH/DELETE with SSRF protection; GET converts HTML → Markdown.
- `web_search` fans out over Tavily / Brave / Perplexity / DuckDuckGo with auto-fallback.
- `apply_patch` uses the `*** Begin Patch` / `*** Update File:` / `@@` hunk format.
- `skill_list` **works from inside an agent** even though the `openfang skill list` CLI shows nothing
  — that is the documented workaround for discovering the 61 bundled skills (see `automation.md`).
- Which tools a given agent may call is gated by `[capabilities]` in its `agent.toml`
  (see `agents.md`) — the tool existing does not mean the agent can use it.

---

## Quick recipes

```bash
# Is the daemon actually up?  000 = down, 200 = up
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4200/api/health

# One-shot health picture
curl -s http://127.0.0.1:4200/api/health/detail | python3 -m json.tool

# Ground truth for channels (better than `openfang channel list`, which shows 8 of 44)
curl -s http://127.0.0.1:4200/api/channels | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))'

# Token spend so far
curl -s http://127.0.0.1:4200/api/usage/summary | python3 -m json.tool
```

All read-only. Note the missing trailing slashes — that is deliberate.
