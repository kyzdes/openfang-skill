# OpenFang Channels (v0.6.9)

**Read this when** the task involves how a message gets *into* an agent or a reply gets *out*:
Telegram (in production on this install), `openfang channel` subcommands, `[channels.*]` config,
a bot that has gone silent, or wiring any of the other 43 adapters.

**This install:** Telegram only. Bot `@OpenAPIModelsBot`, gated to one user
(`allowed_users = ["83979215"]`), token from `TELEGRAM_BOT_TOKEN` in `secrets.env`.

---

## The first thing to know: "the bot is silent" is usually NOT a channel problem

**Symptom (VERIFIED, this install, 2026-07-13):** messages to the Telegram bot got no reply, while
the boot log showed the bot connected perfectly.

The bridge logs a healthy start like this — if you see these four lines, **Telegram is fine**:

```
openfang_channels::telegram: Telegram bot @OpenAPIModelsBot connected
openfang_channels::telegram: Telegram: cleared webhook, polling mode active
openfang_channels::telegram: Telegram: registered 27 bot commands
openfang_api::channel_bridge: telegram channel bridge started
```

In the 2026-07-13 incident the real failure was one line further down:

```
openfang_channels::bridge: Agent error for b09ea7eb-…: LLM driver error: Provider overloaded:
  {"error":{"message":"Failed to generate completions: Failed to apply prompt template:
   invalid operation: This model only supports single tool-calls at once! (in default:95)"}}
```

`minimaxai/minimax-m2.7` could not render parallel tool-calls; switching the default to
`moonshotai/kimi-k2.6` fixed it. Full story in `models-providers.md`.

### 🪤 `Agent error for` is NOT the model/channel discriminator — do not triage on it

An earlier revision of this file said *"Any `Agent error for` lines? → it's the model; no lines → not
the model."* **That test is false and it routes you to a wrong answer.** It was generalised from the
single seed incident above (a user happened to be typing at the bot) into a universal rule.

**VERIFIED, this install, `~/.openfang/daemon-start.log`, boot 07:55:07 → SIGTERM 08:36:41** — the
model chain was 100% the culprit and `Agent error for` never appears:

```bash
L=~/.openfang/daemon-start.log
for s in "Agent error for" "Fallback driver failed" "Agent loop failed" "LLM error classified"; do
  printf '%-24s %s\n' "$s" "$(sed -E 's/\x1b\[[0-9;]*m//g' "$L" | grep -cF "$s")"
done
```
```
Agent error for          0        ← the "discriminator" says "not the model". It is lying.
Fallback driver failed   178      ← the chain exhausted 20 times over 38 minutes
Agent loop failed        20
LLM error classified     20
```

**Why it is zero — the root cause of the false negative (VERIFIED):** `Agent error for <uuid>` is
emitted by `openfang_channels::bridge` **only on the inbound-message path**. During that whole boot
the Telegram-bound `assistant` agent was never invoked at all:

```bash
sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log | grep -c b09ea7eb   # → 0
sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log \
  | grep -F 'Agent loop failed' | grep -oE 'agent_id=[0-9a-f-]+' | sort | uniq -c
#   13 agent_id=91c689c2-…   (orchestrator)
#    7 agent_id=cbbfb77e-…
```

`b09ea7eb` = `assistant` = the agent `delivery.last_channel` points at. **Zero hits.** The 20
failures are background/cron/heartbeat ticks, which fail through `openfang_kernel::kernel` and log
`Agent loop failed — recorded in supervisor` instead.

So `Agent error for` counts **"did an inbound message fail"**, not **"is the model broken"**. Its
absence means *nobody messaged the bot* — which is the normal state of a log, and tells you nothing
about model health.

**Use this instead. `Fallback driver failed` anywhere is sufficient to indict the model chain**,
whatever `Agent error for` says:

| String | Module | What it actually proves |
|---|---|---|
| `Fallback driver failed, trying next driver_index=N` | `openfang_runtime::drivers::fallback` | **A driver in the chain died.** Present at all → model chain is sick. `driver_index` tells you how deep. |
| `LLM error classified: … category=… retryable=…` | `openfang_runtime::agent_loop` | The chain **exhausted** — one line per user-visible failure. |
| `Agent loop failed — recorded in supervisor agent_id=…` | `openfang_kernel::kernel` | A **background/cron** agent tick died. |
| `Agent error for <uuid>` | `openfang_channels::bridge` | An **inbound message** died. Absent ⇒ *no inbound message*, **not** *healthy model*. |

**Corollary trap — `grep ERROR` finds nothing.** This install logged **0** `ERROR` lines while the
entire inference chain was down for 38 minutes; all 2407 are `WARN`. Never triage by log level.

**🚨 The inbound message path is INVISIBLE in the log. VERIFIED 2026-07-14 on a live daemon.** The
Telegram adapter logs **only three lines, ever** — at startup:
```
openfang_channels::telegram: Telegram bot @OpenAPIModelsBot connected
openfang_channels::telegram: Telegram: cleared webhook, polling mode active
openfang_channels::telegram: Telegram: registered 27 bot commands
```
There is **no** "Received message", no "Routing", no user-id, no per-message line at any level
(`grep -icE "Received|incoming|from_user|Routing"` → `0`). So you **cannot** confirm from the log
that a message ever arrived, nor that the bot saw it. Consequences for a silent-bot triage:
- **`0` "Agent error" lines is NOT proof the bot is healthy** — it is equally consistent with *nobody
  messaged it* and with *the allowlist silently dropped the sender* (`allowed_users`).
- The furthest a log-only diagnosis can go is: daemon up ✔, bridge started ✔, model chain probes ✔
  (see `models-providers.md`). Beyond that you **must** send a real message from an allowlisted
  account and watch for a reply — there is no passive read-only signal.
- **UNVERIFIED:** whether a rejected (non-allowlisted) sender produces *any* log line. Not reproduced
  — it needs a message from an out-of-list account, which this pass could not send.

```bash
sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log | grep -cE '  ?ERROR '   # → 0
```

### Triage order for a silent bot (VERIFIED against the 2026-07-14 incident)

1. **Is the daemon up?**
   `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4200/api/health`
   `000` = down. That is a complete explanation for the **silence** — but **it does NOT mean a
   restart will fix it, and it is NOT a reason to skip step 2.** ⚠️ **This step used to read "Stop
   here… do not diagnose further", which made step 2 unreachable and shipped a wrong fix**: the
   2026-07-14 incident had **two independent faults**, and restarting only cleared the first. **Still
   run step 2 before restarting.** (Use curl, not `openfang status`: `status` boots an ephemeral
   kernel and writes ~9 `audit_entries` rows.)
2. **Is the model chain exhausting?** This is step 2, not step 5 — it is the most common cause here,
   **and it survives a restart.** Run it even when step 1 already said "down".
   ```bash
   sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log \
     | grep -cE 'Fallback driver failed|LLM error classified'
   ```
   Non-zero → **it's the model**, regardless of `Agent error for`. → `models-providers.md`.
3. **Do the four healthy-bridge lines appear** (see below)? Missing → the adapter never started;
   check `bot_token_env` resolves and the token is valid. Present → Telegram is fine.
   **⚠️ Pipe log greps through the redactor — see the token-leak trap below.**
4. **Any `Telegram getUpdates network error` lines?** → network/VPN, see below.
5. **Is the user id in `allowed_users`?** A non-allowlisted user is silently ignored. Check this
   **last** — it only explains a bot that has *never* answered *that user*. If the bot worked
   yesterday and the config is untouched, this is not it.
6. Any `Agent error for` lines? Useful only as **confirmation** that an inbound message failed —
   never as a negative test.

---

## ⚠️ `openfang channel list` shows 8 of 44

**VERIFIED.** The CLI surfaces only: `webchat`, `telegram`, `discord`, `slack`, `whatsapp`,
`signal`, `matrix`, `email`.

**44 channel types are compiled into the binary.** The other 36 are configurable only by
hand-editing `config.toml`. `GET /api/channels` is the ground truth (it returns the full catalog
*with* per-field schemas).

Full compiled-in list (UPSTREAM-BINARY, from `[channels.*]` strings):

`telegram` `slack` `discord` `whatsapp` `signal` `matrix` `email` `webchat` `webhook` `irc` `xmpp`
`mastodon` `bluesky` `nostr` `reddit` `discourse` `gitter` `gotify` `ntfy` `zulip` `viber`
`messenger` `line` `teams` `wecom` `feishu` `dingtalk` `dingtalk_stream` `mumble` `threema` `twist`
`twitch` `linkedin` `keybase` `nextcloud` `google_chat` `guilded` `revolt` `rocketchat` `mattermost`
`webex` `pumble` `flock` `history`

---

## Telegram

### Config (VERIFIED — this install's `config.toml`)

```toml
[channels.telegram]
allowed_users = ["83979215"]        # Telegram numeric user IDs; empty/absent = nobody gated in
bot_token_env = "TELEGRAM_BOT_TOKEN" # NAME of the env var, not the token itself
```

The token lives in `~/.openfang/secrets.env` (mode `0600`). The config only ever stores the *name*
of the env var — never paste a token into `config.toml`.

### 🚨 The daemon leaks the bot token into a world-readable log — DOCUMENT, do not "fix"

**VERIFIED, this install, 2026-07-14.** `secrets.env` hygiene is correct and irrelevant, because
`openfang` prints the **full `getUpdates` URL — token inline — into `~/.openfang/daemon-start.log`
on every Telegram network error.** That log is **mode `0664` (world-readable)**:

```bash
ls -l ~/.openfang/daemon-start.log   # -rw-rw-r--  ← 0664, any local user can read it
ls -l ~/.openfang/secrets.env        # -rw-------  ← 0600, correct, and beside the point

# count occurrences WITHOUT printing the token
sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log \
  | grep -cE 'api\.telegram\.org/bot[0-9]+:'      # → 4
```

The logged token is the **live** one (confirmed by matching against `secrets.env` without printing
either value — 4 hits):

```bash
TOK=$(grep -oP '(?<=^TELEGRAM_BOT_TOKEN=).*' ~/.openfang/secrets.env)
sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log | grep -cF "$TOK"   # → 4
```

**Why this bites you specifically:** the leak rides on the `Telegram getUpdates network error` line
— the exact line triage step 4 tells you to grep for. **The naive `grep -i telegram
~/.openfang/daemon-start.log` puts the live token on your screen and into your transcript.**

**Rules.**
- **Never print the token.** Always pipe log greps through the redactor:
  ```bash
  sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log \
    | sed -E 's#(bot[0-9]{3})[0-9]*:[A-Za-z0-9_-]+#\1<REDACTED>#g' \
    | grep -i telegram | tail -10
  ```
  (Keeps the first 3 digits so you can still correlate lines; drops the secret.)
- **Do not `chmod` the log, and do not rotate the token yourself.** Report it. Remediation is
  @BotFather revoke+reissue by the owner — a `chmod` does not un-leak a token that has already been
  read, and `openfang` will re-leak the new one on the next network error anyway.
- Rotation is **mandatory, not optional, if this log was ever shared, pasted, or committed.**

**UNVERIFIED:** whether other adapters leak their tokens the same way. The mechanism is the generic
"log the request URL on error" pattern, and every REST-based adapter puts its token in the URL path
or query — so assume yes until checked. Not reproduced (Telegram is the only channel on this box).

Live schema from `GET /api/channels` (VERIFIED, daemon up):

```json
{"category":"messaging","display_name":"Telegram",
 "description":"Telegram Bot API — long-polling adapter","difficulty":"Easy",
 "config_template":"[channels.telegram]\nbot_token_env = \"TELEGRAM_BOT_TOKEN\"",
 "fields":[
   {"key":"bot_token_env","label":"Bot Token","type":"secret","required":true,
    "env_var":"TELEGRAM_BOT_TOKEN","has_value":true,"placeholder":"123456:ABC-DEF..."},
   {"key":"allowed_users","label":"Allowed User IDs","type":"list","required":false,
    "advanced":true,"value":"83979215"}]}
```

### Transport

**Long-polling `getUpdates`, not webhooks.** The adapter actively *clears* any webhook at boot
(`Telegram: cleared webhook, polling mode active`). Consequences:
- No inbound port, no public URL, no TLS to arrange — it works behind NAT. Good for this box.
- Only one poller may hold the token. Running a second OpenFang (or any other bot process) against
  the same token causes Telegram `409 Conflict`. **UNVERIFIED here** — not reproduced, but it is
  how the Bot API behaves.

### `Telegram getUpdates network error` — the poller lost the network

**VERIFIED, this install (4 occurrences, boot of 2026-07-14).** Verbatim, redacted:

```
07:55:48.052  WARN openfang_channels::telegram: Telegram getUpdates network error: error sending
              request for url (https://api.telegram.org/bot804<REDACTED>/getUpdates), retrying in 1s
07:55:49.059  … retrying in 2s
07:55:51.064  … retrying in 4s
07:55:55.072  … retrying in 8s
```

**Exponential backoff, 1s → 2s → 4s → 8s.** Onset 41s after `bridge started` — on this box that
smells like the Wi-Fi/VPN blip documented in the machine's own notes, not an OpenFang fault. Telegram
reachability is a one-liner: `curl -s -o /dev/null -w '%{http_code}' https://api.telegram.org` (302 =
reachable).

**⚠️ The trap: you cannot positively confirm the poller recovered.** There is **no "polling resumed"
INFO line** — these 4 WARNs are the *last* `openfang_channels::telegram` lines in the entire 41
minutes of uptime, right up to SIGTERM. Recovery is inferred **only from the absence of a 5th
backoff line** (~07:56:03). That is an inference, not an observation, and it is the difference
between "transient blip" and "the bot has been deaf for 40 minutes".

**How to settle it — do not guess:** silence in the log is ambiguous, so prove liveness from the
other side. The `usage_events` table is the ground truth that inbound work is flowing:

```bash
sqlite3 ~/.openfang/data/openfang.db \
  "SELECT model, COUNT(*), MAX(timestamp) FROM usage_events GROUP BY model;"   # note: timestamp, NOT created_at
```
A `MAX(timestamp)` that advances after a test message = the poller is alive. If it does not move,
the poller is deaf and the daemon needs a restart (`daemon-lifecycle.md`).

**UNVERIFIED:** whether the backoff caps or gives up permanently after N attempts. Only 4 retries
were ever observed here and attempt 5 evidently succeeded, so the ceiling was never reached. Do not
assume the poller retries forever.

### Useful per-channel keys (UPSTREAM-BINARY)

| Key | Meaning |
|---|---|
| `output_format` | `telegram_html` / `slack_mrkdwn` / `plain_text` |
| `message_thread_id` | per-topic routing in forum groups (added 0.6.8, upstream #780) |
| `thread_routes` | map a thread to a named agent |
| `default_chat_id` | where unsolicited/cron output goes if nothing else resolves |
| `rate_limit_per_user`, `rate_limit_per_minute` | throttling |
| `typing_mode`, `lifecycle_reactions` | UX: typing indicator, reaction on receipt |
| `usage_footer` | append token/cost footer to replies |
| `prefix_agent_name` | prefix replies with the agent name |
| `max_chars`, `max_response_bytes`, `suppress_patterns`, `debounce_ms` | output shaping |
| `commands_only`, `ignore_bots` | input filtering |

Related fixes already in 0.6.9 (UPSTREAM, GitHub releases):
- **0.6.2 / #1100** — Telegram send errors now return `Err` instead of warn-and-continue. A failed
  send is now visible in the log rather than silently swallowed.
- **0.6.3 / #1133** — `REACTION_TOO_MANY` is no longer cached as a permanent rejection.
- **0.6.5 / #915** — `metadata.telegram_user_id` is surfaced, and the prompt gets a
  `[From: Name (tg_id:NNN)]` prefix.
- **0.6.1 / #1120** — the router keys on `user_id`, not `channel_id`.

---

## How a message round-trips

```
Telegram getUpdates
   └─> openfang-channels::telegram   (allowed_users gate)
        └─> openfang_api::channel_bridge
             └─> agent loop  ──> LLM (gonka → fallbacks)   ← this is where it usually breaks
                  └─> reply
                       └─> bridge resolves the destination
                            └─> kv_store: delivery.last_channel
```

### `delivery.last_channel` — undocumented and operationally critical

**VERIFIED (this install):** the `kv_store` table holds, for agent `assistant`:

```json
delivery.last_channel = {"channel":"telegram","recipient":"83979215"}
```

This is how a **cron job or an autonomous tick** figures out where to send its output when the
`CronDeliveryTarget` is `last_channel` (see `automation.md`). It is written by the channel bridge on
the last inbound message.

**Implication:** an agent that has never received an inbound message has **no `last_channel`**, so a
scheduled job configured to reply to `last_channel` has nowhere to go. If you want a scheduled agent
to post to Telegram reliably, either message it once from Telegram first, or configure an explicit
channel target rather than relying on `last_channel`.

Inspect it read-only:

```bash
sqlite3 ~/.openfang/data/openfang.db \
  "SELECT agent_id, key, value FROM kv_store WHERE key LIKE 'delivery%' LIMIT 10;"
```

---

## CLI

```
openfang channel list              # only 8 of 44 — use GET /api/channels for the truth
openfang channel setup [CHANNEL]   # interactive picker if CHANNEL omitted
openfang channel test <CHANNEL>    # send a test message
openfang channel enable <CHANNEL>
openfang channel disable <CHANNEL>
```

`setup` is interactive and writes config — **do not run it unattended**; prefer editing
`config.toml` directly (and mind the `config set` comment-stripping trap in `config-reference.md`).

---

## 🚨 WhatsApp — do not enable on this box

WhatsApp is **not** a native Rust adapter. It is a **Node.js sidecar** (`whatsapp_gateway.rs`):
requires Node ≥ 18, npm-installs into `node_modules`, listens on `WHATSAPP_GATEWAY_PORT`, and
self-updates its `index.js` on binary upgrade.

Its open, **unanswered** upstream security issues (UPSTREAM — upstream is abandoned, so these will
never be fixed):

| Issue | Problem |
|---|---|
| [#1232](https://github.com/RightNow-AI/openfang/issues/1232) | No auth between the gateway and the Rust API |
| [#1233](https://github.com/RightNow-AI/openfang/issues/1233) | No auth on the gateway's own HTTP API + **wildcard CORS** |
| [#1234](https://github.com/RightNow-AI/openfang/issues/1234) | Untrusted message content forwarded unfiltered to the LLM |

Combined with agents that hold `shell_exec` and `network = ["*"]`, that is a remote-code-execution
shaped hole. **Leave WhatsApp off unless you have read the gateway source yourself.**

Also worth knowing: **Matrix has no E2EE** ([#1177](https://github.com/RightNow-AI/openfang/issues/1177), UPSTREAM).

---

## Adding a channel — the honest procedure

1. Get the real field list: `curl -s http://127.0.0.1:4200/api/channels` and find your channel's
   `fields[]` + `config_template`. Do **not** trust `channel list`.
2. Put the secret in `~/.openfang/secrets.env` as `SOMETHING_TOKEN=…` (0600).
3. Add `[channels.<name>]` to `config.toml` by hand, referencing the env var **by name**
   (`token_env = "SOMETHING_TOKEN"`), and gate access (`allowed_users` / `allowed_guilds` / …).
4. **Restart the daemon** — channel config is read at boot. See `daemon-lifecycle.md` for the safe
   restart (never bare `nohup`).
5. Verify in the log: the adapter should print its own "connected" + "bridge started" pair.
   **Always via the redactor** — adapters log their token inline on network errors (see the
   Telegram token-leak trap above; assume yours does too):
   ```bash
   sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log \
     | sed -E 's#(bot[0-9]{3})[0-9]*:[A-Za-z0-9_-]+#\1<REDACTED>#g' \
     | grep -iE '<name>|bridge started' | tail
   ```

**Always gate access.** An ungated channel means anyone who finds the bot can drive an agent that
may hold `shell_exec`.
