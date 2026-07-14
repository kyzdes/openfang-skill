# OpenFang config reference (v0.6.9)

**Read this when** you must change, read, validate, or debug anything under `~/.openfang/config.toml`,
`secrets.env`, `.env`, the vault, `OPENFANG_*` env vars, provider/channel key env vars, config
hot-reload, the `include` directive, or when `openfang doctor` disagrees with a daemon that is
plainly working. If the task is agent manifests (`agents/<name>/agent.toml`), models/providers
catalog, or channels, this is the wrong doc — but note the **root config and agent manifests are
different schemas** and are routinely confused (see [Not in this file](#not-in-this-file)).

Evidence marks: **VERIFIED** = observed on this install, command + real output shown.
**UPSTREAM** = read from the v0.6.9 source/repo, path cited. **SUSPECT** = contradictory evidence.
**UNVERIFIED** = could not test, reason given.

Install under test: binary `/home/kyzdes/.openfang/bin/openfang` (v0.6.9), home `/home/kyzdes/.openfang`.
**The daemon was DOWN during this research** — everything needing a live kernel is marked UNVERIFIED.

---

## The four things that waste the most time (read first)

1. **`--config <PATH>` is accepted by every config subcommand and is COMPLETELY IGNORED.** It is
   advertised in `--help`, parses without error, and silently operates on `~/.openfang/config.toml`
   anyway. **`OPENFANG_HOME` is the only working redirect.** Getting this wrong means you edit or
   read production while believing you are in a sandbox. VERIFIED below.

2. **A config typo does not fail — it silently reverts you to `KernelConfig::default()`, which is
   `provider = "anthropic"`, `model = "claude-sonnet-4-20250514"`, `api_key_env = "ANTHROPIC_API_KEY"`.**
   On this install there is no `ANTHROPIC_API_KEY`, so a one-character syntax error turns all 30
   agents into `Missing API key: Set ANTHROPIC_API_KEY` — with one `WARN` line as the only clue.

3. **Unknown keys and misspelled sections are silently ignored** (`deny_unknown_fields` is
   deliberately NOT on `KernelConfig`). `[defaul_model]` does not error — it is dropped, and you
   get the anthropic default. `doctor` reports **`✔ Config deserializes into KernelConfig`** for a
   config full of typos. This is the single most dangerous property of the whole subsystem.

4. **`doctor`'s "No LLM provider API keys found!" is a false alarm — and it is NOT the file-path
   problem it looks like.** `.env` and `secrets.env` are BOTH loaded by one loader (§5); doctor
   proves it by reporting `TELEGRAM_BOT_TOKEN` `ok` from `secrets.env`. The provider check fails
   because it is a hardcoded whitelist of 11 canonical env var names, and `GONKA_1_API_KEY` /
   `NIM_1_API_KEY` are not on it. **It is blind, not pessimistic: it emits an identical 11×`warn`
   whether the keys are perfect or completely absent — VERIFIED in a zero-key sandbox (§6). So it can
   neither confirm nor deny a custom key. Never triage keys with `doctor`; never "fix" it with
   `config set-key`.** Also: **`doctor` exits 0 when checks fail**, and `all_ok=false` is this
   install's permanent healthy steady state — never gate a script on either.

---

## 1. Config file resolution — `--config` is a lie

UPSTREAM `crates/openfang-kernel/src/config.rs:344-359`:

```rust
/// Respects `OPENFANG_HOME` env var (e.g. `OPENFANG_HOME=/opt/openfang`).
pub fn default_config_path() -> PathBuf { openfang_home().join("config.toml") }

/// Priority: `OPENFANG_HOME` env var > `~/.openfang`.
pub fn openfang_home() -> PathBuf {
    if let Ok(home) = std::env::var("OPENFANG_HOME") { return PathBuf::from(home); }
    dirs::home_dir().unwrap_or_else(std::env::temp_dir).join(".openfang")
}
```

`load_config(path: Option<&Path>)` DOES honour an explicit path — but the CLI's `config` subcommand
never threads `--config` into it. VERIFIED, three ways:

```bash
$ printf 'api_listen = "127.0.0.1:9999"\nlog_level = "debug"\n' > /tmp/sp/alt.toml

$ openfang config show --config /tmp/sp/alt.toml | head -3
# /home/kyzdes/.openfang/config.toml        # <-- WRONG FILE. Flag ignored.
api_listen = "127.0.0.1:4200"

$ openfang --config /tmp/sp/alt.toml config show | head -3
# /home/kyzdes/.openfang/config.toml        # <-- also ignored before the subcommand
api_listen = "127.0.0.1:4200"

$ OPENFANG_HOME=/tmp/sp/home openfang config show | head -3
# /tmp/sp/home/config.toml                  # <-- OPENFANG_HOME works
api_listen = "127.0.0.1:9999"
log_level = "debug"
```

**Rule: to operate on a non-default config, set `OPENFANG_HOME`. Never trust `--config`.**
This is also your only safe sandbox for testing config changes without touching production.

---

## 2. This install's actual `config.toml`, annotated

```bash
$ wc -l /home/kyzdes/.openfang/config.toml && ls -l /home/kyzdes/.openfang/config.toml
47 /home/kyzdes/.openfang/config.toml
-rw------- 1 kyzdes kyzdes 1193 Jul 14 09:54 /home/kyzdes/.openfang/config.toml
```

Mode `0600`. **Note it has zero comments and every key is alphabetically sorted inside each table —
that is the fingerprint of a file that has been rewritten by `openfang config set`** (§7).

```toml
api_listen = "127.0.0.1:4200"
# Root-level key (NOT [api].api_listen — see §3 migration). Loopback bind =>
# api_key may stay empty; security mode reports "localhost_only". Changing this
# requires a RESTART (§8) — it is not hot-reloadable.

[channels.telegram]
allowed_users = ["83979215"]
# Allowlist of Telegram user IDs. Strings, not ints.
bot_token_env = "TELEGRAM_BOT_TOKEN"
# Name of the env var, NOT the token. Resolved from secrets.env (§5).
# [channels] IS hot-reloadable => HotAction::ReloadChannels (§8).

[default_model]
api_key_env = "GONKA_1_API_KEY"
base_url    = "https://api.gonkagate.com/v1"
model       = "moonshotai/kimi-k2.6"
provider    = "gonka-1"
# "gonka-1" is a CUSTOM provider id, not a built-in. Because no [provider_api_keys]
# mapping exists, the convention {PROVIDER_UPPER}_API_KEY would give "GONKA-1_API_KEY";
# the explicit api_key_env here is what makes it resolve. Keep it.
# TRAP: this provider name is invisible to `doctor` (§6) -> "No LLM provider API keys found!".
# TRAP (UPSTREAM #1195): slashed model IDs on a custom base_url can have the namespace
# stripped ("moonshotai/kimi-k2.6" -> "kimi-k2.6" -> model_not_found). Reported scoped to
# provider="openai"; this install uses provider="gonka-1" and works. SUSPECT: settle by
# grepping the daemon log for the outbound model string on a live request.

[[fallback_providers]]        # x4 (gonka-2/3/4) + x1 (nim-1)
api_key_env = "GONKA_2_API_KEY"
base_url    = "https://api.gonkagate.com/v1"
model       = "moonshotai/kimi-k2.6"
provider    = "gonka-2"
# ...gonka-3, gonka-4 identical shape...

[[fallback_providers]]
api_key_env = "NIM_1_API_KEY"
base_url    = "https://integrate.api.nvidia.com/v1"
model       = "meta/llama-3.3-70b-instruct"
provider    = "nim-1"
# Last-resort link in the chain (driver_index 0..4). SEED records 235 audit rows of
# "error sending request for url https://integrate.api.nvidia.com/v1/chat/completions"
# => this last resort is unreachable from this host. The chain effectively ends at gonka-4.

[memory]
decay_rate         = 0.05
embedding_model    = "mxbai-embed-large"
embedding_provider = "ollama"
# [memory] is RESTART-REQUIRED (§8) — editing these live does nothing until restart.
# embedding_api_key_env is unset: correct, ollama needs no key.
# UPSTREAM #1212/#1251: the openai embedding driver hardcodes 6 cloud providers and
# ignores/mangles base_url. provider="ollama" is the path that works here.

[provider_urls]
gonka-1 = "https://api.gonkagate.com/v1"
gonka-2 = "https://api.gonkagate.com/v1"
gonka-3 = "https://api.gonkagate.com/v1"
gonka-4 = "https://api.gonkagate.com/v1"
nim-1   = "https://integrate.api.nvidia.com/v1"
# provider id -> base URL override map. REDUNDANT here: every entry duplicates the
# base_url already given inline in [default_model]/[[fallback_providers]]. Harmless.
# Hot-reloadable => HotAction::ReloadProviderUrls.
```

### Corrections to the SEED you must not propagate

| SEED said | Truth |
|---|---|
| `[[fallback_models]]` in config.toml | **`[[fallback_providers]]`.** VERIFIED — it is what is in the file and what `KernelConfig.fallback_providers` deserializes. `[[fallback_models]]` is an **agent.toml** key. Using it in config.toml = silently ignored (§4) = no fallback chain. |
| doctor mismatch = "two secret paths, no cross-awareness" | Wrong mechanism. One loader reads both files. It is a **name whitelist** problem (§6). |
| `[provider_urls]` not listed | It exists and is live on this install. |
| Config schema ≈ 20 sections | Root `KernelConfig` has **45 fields**; the types file is 4701 lines (§4). |

Backups present (all `0600`): `config.toml.bak`, `.bak-embeddings`, `.bak-telegram-fix`.
`diff config.toml.bak config.toml` = one line: `+ embedding_model = "mxbai-embed-large"`. VERIFIED.

---

## 3. The load pipeline (exact order)

UPSTREAM `crates/openfang-kernel/src/config.rs:18-120`. Every failure branch below ends at
`KernelConfig::default()` and only logs a `warn!`.

```
default_config_path()  = $OPENFANG_HOME/config.toml  or  ~/.openfang/config.toml
  │
  ├─ file missing ─────────────► info!("Config file not found, using defaults")      → DEFAULTS
  ├─ read error ───────────────► warn!("Failed to read config file, using defaults") → DEFAULTS
  ├─ toml::from_str fails ─────► warn!("Failed to parse config, using defaults")     → DEFAULTS
  │
  ├─ resolve_config_includes()  (§9)
  │     └─ any error ──────────► warn!("Config include resolution failed, using root config only")
  │                               (NOT fatal; ALL includes discarded, root config still used)
  ├─ remove the `include` key from the tree
  ├─ MIGRATE [api].{api_key,api_listen,log_level} → root, only if root lacks the key
  │     └─ info!("Migrating misplaced config field from [api] to root level")
  ├─ lenient_extract_bindings()  — GAP-012 Tier 1: per-entry [[bindings]] pre-validation;
  │     malformed entries logged at ERROR and DROPPED, survivors kept
  │
  └─ root_value.try_into::<KernelConfig>()
        ├─ Ok  ► info!("Loaded configuration")                                        → CONFIG
        └─ Err ► warn!("Failed to deserialize merged config, using defaults")         → DEFAULTS
```

**The `[api]` → root migration (UPSTREAM, `config.rs:56-70`)** is an undocumented compatibility
shim. An old-schema config with `[api] api_listen = ...` still works; root wins if both are set.
Only `api_key`, `api_listen`, `log_level` are migrated — nothing else under `[api]` is read.

### The defaults you fall back to — the actual blast radius

UPSTREAM `crates/openfang-types/src/config.rs:1703-1712`:

```rust
impl Default for DefaultModelConfig {
    fn default() -> Self { Self {
        provider:  "anthropic".to_string(),
        model:     "claude-sonnet-4-20250514".to_string(),
        api_key_env: "ANTHROPIC_API_KEY".to_string(),
        base_url: None, subprocess_timeout_secs: None,
    }}
}
```

**On this install `ANTHROPIC_API_KEY` does not exist.** So the degradation is not "slightly wrong
model" — it is total: every agent fails to boot with `Missing API key: Set ANTHROPIC_API_KEY`,
`api_listen` reverts to the built-in default, `[channels.telegram]` vanishes (bot goes silent), and
the whole fallback chain disappears. Upstream acknowledges this in a code comment
(`config.rs:88-96`):

> `TODO(GAP-012-Tier-2): this fallback still silently swaps the user's intent for
> KernelConfig::default() on any non-binding deserialization failure. Tier 1 closes the
> binding-shape footgun; Tier 2 should surface remaining failures via a health endpoint and/or
> stderr banner so the silent-default path can't hide a broken config.`

**Detection — the only reliable pre-flight.** `openfang config get` parses the file and refuses to
guess; `config show` does not parse at all. VERIFIED:

```bash
$ printf 'api_listen="127.0.0.1:9999"\nlog_level="debug"\nnot valid =\n' > $H/config.toml

$ OPENFANG_HOME=$H openfang config show     # NO validation — raw cat of the file
# /tmp/sp/home/config.toml
api_listen = "127.0.0.1:9999"
log_level = "debug"
not valid =                                  # <-- happily prints broken TOML

$ OPENFANG_HOME=$H openfang config get api_listen; echo "exit=$?"
  ✘ Config parse error: TOML parse error at line 3, column 5
  |
3 | not valid =
exit=1                                       # <-- exit 1. THIS is your syntax gate.
```

Grep the daemon log for the degradation after any restart:

```bash
grep -E 'using defaults|using root config only|Migrating misplaced' \
  /home/kyzdes/.openfang/daemon-start.log | tail -20
```

---

## 4. Root schema — `KernelConfig` (45 fields)

UPSTREAM `crates/openfang-types/src/config.rs:1145+`. `#[serde(default)]` on the struct ⇒ every
field is optional and every omission is a default.

**Unknown fields are ignored on purpose** (`config.rs:1135-1143`):

> `deny_unknown_fields` is intentionally *not* applied here. Strict-field validation is scoped to
> bindings (`AgentBinding` + `BindingMatchRule`), where silent no-op routing is the failure mode
> worth catching loudly. Adding it to the top-level kernel struct would also reject forward-compat
> keys, downstream-fork-only keys, and "I'm trying out a future field early" workflows.

VERIFIED — a config of pure garbage passes every validator:

```bash
$ printf 'api_listen="127.0.0.1:9999"\nbogus_key_xyz="hi"\n[bogus_section]\nfoo=1\n' > $H/config.toml
$ OPENFANG_HOME=$H openfang doctor --json | jq -c '.checks[]|select(.check|test("config"))'
{"check":"config_file","status":"ok"}
{"check":"config_deser","status":"ok"}       # <-- "ok". Typos are invisible.
```

Contrast — a **type** error IS caught (this is the only class `config_deser` detects):

```bash
$ printf 'api_listen=1234\n' > $H/config.toml
$ OPENFANG_HOME=$H openfang doctor --json | jq -c '.checks[]|select(.check=="config_deser")'
{"check":"config_deser","status":"fail","error":"TOML parse error at line 1, column 12\n  |\n1 | api_listen=1234\n  |            ^^^^\ninvalid type: integer `1234`, expected a string\n"}
```

**So: `config_deser: ok` means "no type errors", NOT "your config means what you think".**

### Root keys

| Key / section | Type | Default | Reload | Notes |
|---|---|---|---|---|
| `home_dir` | path | `~/.openfang` | **restart** | |
| `data_dir` | path | `~/.openfang/data` | **restart** | |
| `log_level` | string | `"info"` | no-op | trace/debug/info/warn/error. **Changing it live does nothing** — logged as a no-op change. |
| `api_listen` | string | — | **restart** | alias **`listen_addr`** accepted. Validator: cannot be empty. |
| `api_key` | string | `""` | **restart** | Empty ⇒ API unauthenticated. Non-loopback binds require it: `API key required for non-loopback requests. Set OPENFANG_API_KEY or bind to 127.0.0.1.` |
| `network_enabled` | bool | `false` | **restart** | Validator: if true, `network.shared_secret` must be non-empty. |
| `mode` | enum | `default` | no-op | `stable` \| `default` \| `dev`. `stable` freezes the skill registry (`Skill registry is frozen (Stable mode)`). |
| `language` | string | `"en"` | no-op | |
| `max_cron_jobs` | usize | **500** | hot | Validator: `> 10000` rejected. SEED omitted the default. |
| `include` | array<string> | `[]` | n/a | §9. **Must be an array** — a bare string fails deser. |
| `[default_model]` | table | anthropic/claude-sonnet-4 | **hot** | §2. |
| `[[fallback_providers]]` | array | `[]` | hot | `provider`, `model` required; `api_key_env`, `base_url`, `subprocess_timeout_secs` optional. |
| `[memory]` | table | see below | **restart** | |
| `[network]` | table | — | **restart** | `shared_secret`, `bootstrap_peers`, `mdns_enabled`, `max_peers`, `listen_port`, `peer_id`. |
| `[channels]` | table | — | **hot** | `[channels.<name>]`; 44 adapters compiled in. |
| `[provider_urls]` | map<str,str> | `{}` | hot | provider id → base URL. |
| `[provider_api_keys]` | map<str,str> | `{}` | **no-op** | provider id → **env var NAME**. Fallback convention: `{PROVIDER_UPPER}_API_KEY`. Change logs `provider_api_keys changed (takes effect on next driver init)` — i.e. **not actually applied**. |
| `[[users]]` | array | `[]` | **not diffed** | RBAC: `name`, `role` (default `user`), `channel_bindings`, `api_key_hash`. |
| `[[mcp_servers]]` | array | `[]` | hot | |
| `[a2a]` | table? | `None` | hot | |
| `usage_footer` | enum | | hot | |
| `[web]` | table | | hot | `search_provider` (brave/tavily/perplexity/searxng), `cache_ttl_minutes`, per-provider `api_key_env`, `[web.fetch]` `max_chars`/`max_response_bytes`/`timeout_secs`/`readability`/`ssrf_allowed_hosts`. |
| `[browser]` | table | | hot | `enabled`, `headless`, `viewport_*`, `timeout_secs`, `idle_timeout_secs`=300, `max_sessions`=5, `chromium_path`. |
| `[extensions]` | table | | hot | |
| `[vault]` | table | `enabled=true, path=None` | **restart** | §6. |
| `workspaces_dir` | path? | `~/.openfang/workspaces` | **not diffed** | |
| `workflows_dir` | path? | `~/.openfang/workflows` | **not diffed** | Empty string disables auto-load. |
| `[media]` / `[links]` | table | | **not diffed** | |
| `[reload]` | table | `mode=hybrid, debounce_ms=500` | **not diffed** | §8. |
| `[webhook_triggers]` | table? | `enabled=false` | hot | `token_env`=`OPENFANG_WEBHOOK_TOKEN`, `max_payload_bytes`=65536, `rate_limit_per_minute`=30. **Token must be ≥32 chars if enabled.** |
| `[approval]` | table | | hot | alias **`approval_policy`**. `auto_approve`, `auto_approve_autonomous`, `require_approval`. Has its own `.validate()`. |
| `[exec_policy]` | table | mode=Allowlist | **not diffed** | Live: `{"check":"exec_policy","mode":"Allowlist","safe_bins":18,"status":"ok"}`. |
| `[[bindings]]` | array | `[]` | **not diffed** | **The ONLY `deny_unknown_fields` region.** `agent` + `match_rule`. Not in the SEED. |
| `[broadcast]` | table | | **not diffed** | |
| `[auto_reply]` | table | | **not diffed** | |
| `[canvas]` | table | | **not diffed** | |
| `[tts]` | table | `enabled=false` | **not diffed** | `[tts.openai]`, `[tts.elevenlabs]`, `max_text_length`, `timeout_secs`. |
| `[docker]` | table | | **not diffed** | Container sandbox. |
| `[pairing]` | table | | **not diffed** | |
| `[auth_profiles]` | map<str,array> | `{}` | **not diffed** | provider → profiles, for key rotation. |
| `[thinking]` | table? | `None` | **not diffed** | Extended thinking. |
| `[budget]` | table | all `0.0` | **not diffed** | §10. |
| `[oauth]` | table | | **not diffed** | `google_client_id`, `github_client_id`, `microsoft_client_id`, `slack_client_id`. |
| `[auth]` | table | `enabled=false` | **not diffed** | Dashboard login: `username`="admin", `password_hash` (**Argon2id PHC**), `session_ttl_hours`=168. |
| `[heartbeat]` | table | `default_timeout_secs=180` | **not diffed** | See §10 / UPSTREAM #1252. |
| `[skills.<name>]` | map<str,map> | `{}` | hot | Per-skill config injection; resolution order: **this map → the var's `env` field → the var's `default`**. |

### `[memory]` in full (UPSTREAM `types/config.rs:1716+`)

| Key | Default | Notes |
|---|---|---|
| `sqlite_path` | `None` → `data_dir/openfang.db` | |
| `embedding_model` | **`"all-MiniLM-L6-v2"`** | This install overrides to `mxbai-embed-large`. |
| `embedding_provider` | `None` = **auto-detect** | `"openai"` \| `"ollama"` \| … |
| `embedding_api_key_env` | `None` | |
| `consolidation_threshold` | | max memories before consolidation |
| `consolidation_interval_hours` | **24** | `0` = disabled |
| `decay_rate` | | f32, 0.0 = none, 1.0 = aggressive |
| `backend` | **`"sqlite"`** | or `"http"` |
| `http_url` | `None` | e.g. `http://127.0.0.1:5500` — only when `backend="http"` |
| `http_token_env` | `None` | env var **name** for the bearer token |

`backend`/`http_url`/`http_token_env` are absent from the SEED. The whole section is
**restart-required** — a `[memory]` edit produces `config reload: restart required — memory config changed`
and nothing else happens until you restart.

---

## 5. Secrets: `.env` vs `secrets.env` — one loader, both files

**This is the section the SEED gets wrong.** UPSTREAM `crates/openfang-cli/src/dotenv.rs:19-52`:

```rust
/// Load `~/.openfang/.env` and `~/.openfang/secrets.env` into `std::env`.
///
/// System env vars take priority — existing vars are NOT overridden.
/// `secrets.env` is loaded second so `.env` values take priority over secrets
/// (but both yield to system env vars).
/// Silently does nothing if the files don't exist.
pub fn load_dotenv() {
    load_env_file(env_file_path());        // ~/.openfang/.env
    load_env_file(secrets_env_path());     // ~/.openfang/secrets.env
}

fn load_env_file(path: Option<PathBuf>) {
    // ...
    if let Some((key, value)) = parse_env_line(trimmed) {
        if std::env::var(&key).is_err() { std::env::set_var(&key, &value); }  // first writer wins
    }
}
```

### Precedence (authoritative)

```
process/system env   >   ~/.openfang/.env   >   ~/.openfang/secrets.env
```

First writer wins (`if std::env::var(&key).is_err()`). Both files honour `OPENFANG_HOME`.
Format: `KEY=VALUE`, `#` comments, optional quotes. Hand-rolled parser — **no `export`, no
interpolation, no multi-line values.**

### Who writes which file

| Writer | Target | UPSTREAM |
|---|---|---|
| `openfang config set-key <provider>` | **`.env` only** | `save_env_key()` → `env_file_path()`; help text: *"Save an API key to `~/.openfang/.env`"* |
| `openfang config delete-key` | **`.env` only** | help: *"Remove an API key from `~/.openfang/.env`"* |
| Dashboard "Set API Key" button | **`secrets.env`** | `dotenv.rs:27` comment: *"Also load secrets.env (written by dashboard 'Set API Key' button)"* |
| Channel hot-reload | re-reads `secrets.env` | binary string: `Reloaded secrets.env for channel hot-reload` |

**Trap:** if the same key exists in both files, **`.env` silently wins** — so a `config set-key`
write shadows the dashboard's `secrets.env` value forever, with no warning. To rotate a key that
lives in `secrets.env`, edit `secrets.env`; do not `config set-key` the same name.

### This install

```bash
$ ls -l /home/kyzdes/.openfang/secrets.env; ls -l /home/kyzdes/.openfang/.env
-rw------- 1 kyzdes kyzdes 359 Jul 13 21:58 /home/kyzdes/.openfang/secrets.env
ls: cannot access '/home/kyzdes/.openfang/.env': No such file or directory

$ sed -E 's/=.*/=<REDACTED>/' /home/kyzdes/.openfang/secrets.env
GONKA_1_API_KEY=<REDACTED>
GONKA_2_API_KEY=<REDACTED>
GONKA_3_API_KEY=<REDACTED>
GONKA_4_API_KEY=<REDACTED>
TELEGRAM_BOT_TOKEN=<REDACTED>
NIM_1_API_KEY=<REDACTED>
```

VERIFIED: `secrets.env` is `0600`, six keys, **no `.env` exists**, and none of these vars are in the
shell environment (`env | grep -c '^GONKA_1_API_KEY=' → 0`). The daemon authenticates anyway.

---

## 6. Why `doctor` says "No LLM provider API keys found!" — and why it is wrong

The proof that the loader reads `secrets.env` fine is inside doctor's own output. VERIFIED:

```bash
$ openfang doctor --json | jq -c '.checks[]|select(.check=="channel")'
{"check":"channel","env_var":"TELEGRAM_BOT_TOKEN","name":"Telegram","status":"ok"}
{"check":"channel","env_var":"DISCORD_BOT_TOKEN","name":"Discord","status":"warn"}
{"check":"channel","env_var":"SLACK_APP_TOKEN","name":"Slack App","status":"warn"}
{"check":"channel","env_var":"SLACK_BOT_TOKEN","name":"Slack Bot","status":"warn"}
```

`TELEGRAM_BOT_TOKEN` exists **only in `secrets.env`** and is **not** in the shell env — yet doctor
reports it `ok`. **Therefore doctor loads `secrets.env`.** The provider check nevertheless fails:

```bash
$ openfang doctor --json | jq -r '.checks[]|select(.check=="provider")|"\(.name)\t\(.env_var)\t\(.status)"'
Groq            GROQ_API_KEY               warn
OpenRouter      OPENROUTER_API_KEY         warn
Anthropic       ANTHROPIC_API_KEY          warn
OpenAI          OPENAI_API_KEY             warn
DeepSeek        DEEPSEEK_API_KEY           warn
Gemini          GEMINI_API_KEY             warn
Google          GOOGLE_API_KEY             warn
Together        TOGETHER_API_KEY           warn
Mistral         MISTRAL_API_KEY            warn
Fireworks       FIREWORKS_API_KEY          warn
AWS Bedrock     AWS_BEARER_TOKEN_BEDROCK   warn
```

**Root cause: doctor iterates a hardcoded list of 11 canonical env var names.** It never reads
`default_model.api_key_env` or `[[fallback_providers]].api_key_env`. `GONKA_1_API_KEY` and
`NIM_1_API_KEY` are not on the list ⇒ 11×`warn` ⇒ the banner:

```
  ✘ No LLM provider API keys found!
  hint: Or run: openfang config set-key groq
```

**Verdict: the `provider` check is BLIND on this install, not merely wrong.** It is not that doctor is
pessimistic — **it reports the exact same 11×`warn` whether your keys are perfect or entirely absent.**
VERIFIED, in a throwaway sandbox with the real config and **no `secrets.env` and no `.env` at all**:

```bash
H=/tmp/of-probe; rm -rf $H; mkdir -p $H
cp ~/.openfang/config.toml $H/config.toml          # same [default_model] gonka-1, zero secrets
OPENFANG_HOME=$H openfang doctor --json 2>/dev/null \
  | jq -r '[.checks[]|select(.check=="provider")|.status]|group_by(.)|map("\(.[0])=\(length)")|join(" ")'
# warn=11        <- IDENTICAL to the healthy production install above
rm -rf $H
```

So: **a green-ish `provider` section is impossible here, and a red one proves nothing.** Do not read these 11
warns as a fault, and do not read their absence as health — you cannot get their absence. **Never triage a
missing custom key with `doctor`.**

**The `channel` check IS a real signal — it is the one that actually tracks `secrets.env`.** In the same
zero-key sandbox `TELEGRAM_BOT_TOKEN` flips `ok` → `warn`, whereas on production it reads `ok`. VERIFIED. Use
`channel` to confirm a token is loaded; use nothing for providers.

**Do NOT "fix" the provider warns by running `openfang config set-key groq`** — that writes a useless key to
`.env`, changes nothing about `gonka-1`, and (per §5) permanently shadows any `secrets.env` value of the same
name.

**To actually verify a custom provider key, check the file and the daemon, not doctor:**

```bash
sed -E 's/=.*/=<SET>/' ~/.openfang/secrets.env       # name present? (never print the value)
grep -a 'Kernel booted' ~/.openfang/daemon-start.log | tail -1   # ✔ Kernel booted (gonka-1/…) = key worked
```

The separate `env_file` check is also cosmetic:

```bash
$ openfang doctor --json | jq -c '.checks[]|select(.check=="env_file")'
{"check":"env_file","status":"warn"}
# human: "- .env file not found (create with: openfang config set-key <provider>)"
```

It hard-codes `.env` and is unaware `secrets.env` exists. Both warnings are expected steady-state
on this install. Other verbatim doctor strings: `.env file has loose permissions (`,
`.env file (permissions fixed to 0600)`.

**`doctor` exits 0 even when it fails.** VERIFIED:

```bash
$ openfang doctor > /dev/null 2>&1; echo "exit=$?"
exit=0                      # despite "✘ Some checks failed."
```

**Script against `--json` and read `.all_ok`** (live value here: `false`).

### Full live doctor check inventory (VERIFIED)

`openfang_dir` `env_file` `config_file` `daemon` `port` `database` `disk_space` `agent_manifests`
`provider`×11 `channel`×4 `config_deser` `config_includes`* `exec_policy` `bundled_skills`
`skill_injection_scan` `extensions_available` `extensions_installed` `rust` `python` `node`
(*`config_includes` only appears when `include` is set.)

Steady-state on this install — VERIFIED, re-checked
(`openfang doctor --json | jq -r '.checks[]|select(.status!="ok")|"\(.check)\t\(.status)"' | sort | uniq -c`):

```
     11 provider  warn      <- blind (§6). Expected forever. Not a fault.
      3 channel   warn      <- Discord/Slack unconfigured. Expected. Telegram is `ok`.
      1 daemon    warn      <- down right now. The ONLY row here that tracks something real.
      1 env_file  warn      <- no `.env`; keys live in `secrets.env`. Expected forever.
      1 rust      fail      <- no rustc. Cosmetic unless you build WASM/extensions.
```

`all_ok=false` is the **permanent** steady state of a healthy install here — four of the five rows above can
never go green. **`all_ok` is therefore useless as a health signal on this box; the only row worth reading is
`daemon`, and `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4200/api/health` (`000` = down) answers
that faster and writes nothing.** `python: ok` (3.14.4) and `node: ok` (v24.18.0) — an earlier revision of this
file recorded `node: warn`; that is **stale**, node is present now.

---

## 7. `config show` / `get` / `set` / `unset`

```
openfang config show        # RAW CAT of the file + a "# <path>" header. NO parsing, NO validation.
openfang config get <KEY>   # dotted path. PARSES. exit 1 on parse error or missing key.
openfang config set <K> <V> # "warning: strips TOML comments"
openfang config unset <K>   # "warning: strips TOML comments"
openfang config edit        # $EDITOR
```

### `set`/`unset` destroy comments AND reorder keys — VERIFIED

Run in an `OPENFANG_HOME` sandbox, never against production:

```toml
# BEFORE
# Production config - DO NOT EDIT WITHOUT REVIEW
api_listen = "127.0.0.1:4200"  # bound to loopback on purpose

[default_model]
provider = "gonka-1"   # primary
model = "moonshotai/kimi-k2.6"
```

```bash
$ OPENFANG_HOME=$H openfang config set log_level debug
  ✔ Set log_level = debug
```

```toml
# AFTER — every comment gone; keys alphabetized within each table
api_listen = "127.0.0.1:4200"
log_level = "debug"

[default_model]
model = "moonshotai/kimi-k2.6"
provider = "gonka-1"
```

**Both the header comment and all inline comments are unrecoverable. Back up first:**

```bash
cp -a /home/kyzdes/.openfang/config.toml /home/kyzdes/.openfang/config.toml.bak-$(date +%Y%m%d-%H%M%S)
```

### `set` will NOT create a missing table — VERIFIED

```bash
$ cat $H/config.toml
api_listen = "127.0.0.1:4200"

[default_model]
provider = "gonka-1"

$ OPENFANG_HOME=$H openfang config set default_model.provider gonka-9   # table EXISTS
  ✔ Set default_model.provider = gonka-9

$ OPENFANG_HOME=$H openfang config set memory.decay_rate 0.05           # [memory] MISSING
  ✘ Key path not found: memory.decay_rate
$ echo $?
1
```

**`config set` only edits an existing key path. To add a new section you must hand-edit the TOML.**
Exit code is honest (1), but the message goes to stdout with a `✘` — do not pattern-match on `✔`.

### Value type inference — VERIFIED

`set` infers TOML scalars from the literal: `50` → integer, `true` → bool, everything else → string.

```bash
$ OPENFANG_HOME=$H openfang config set max_cron_jobs 50      # -> max_cron_jobs = 50
$ OPENFANG_HOME=$H openfang config set network_enabled true  # -> network_enabled = true
```

**Trap: `set network_enabled true` alone produces a config the reload validator rejects**
(`network_enabled is true but network.shared_secret is empty`), and `network.shared_secret` cannot
be set by `config set` because `[network]` does not exist yet. Hand-edit both, or don't touch it.

**Trap: array values are not settable.** `config set channels.telegram.allowed_users '["1","2"]'`
was a no-op in testing (the table did not exist); with the table present it would store a *string*.
Hand-edit arrays.

### `get` does NOT resolve includes — VERIFIED

```bash
$ printf 'api_listen="127.0.0.1:9999"\ninclude=["extra.toml"]\n' > $H/config.toml
$ printf 'log_level="trace"\nmax_cron_jobs=42\n' > $H/extra.toml

$ OPENFANG_HOME=$H openfang config get log_level
  ✘ Key not found: log_level        # <-- but the DAEMON sees log_level="trace"
$ OPENFANG_HOME=$H openfang config get max_cron_jobs
  ✘ Key not found: max_cron_jobs
```

**`config get`/`show` operate on the ROOT FILE ONLY. The kernel merges includes. If you use
`include`, the CLI's view of the config is not the daemon's view.** The merged view is only
available from `GET /api/config` on a live daemon (UNVERIFIED — daemon down).

Working reads on this install (VERIFIED):

```bash
$ openfang config get default_model.provider
gonka-1
$ openfang config get memory.embedding_provider
ollama
```

---

## 8. Hot-reload (`config_reload`)

UPSTREAM `crates/openfang-kernel/src/config_reload.rs`. Module doc, verbatim:

> **Hot-reload safe**: channels, skills, usage footer, web config, browser, approval policy, cron
> settings, webhook triggers, extensions.
> **No-op** (informational only): log_level, language, mode.
> **Restart required**: api_listen, api_key, network, memory.

`[reload]`: `mode` = `off` | `restart` | `hot` | **`hybrid`** (default), `debounce_ms` = 500.
Watcher log line: `Config file changed, reloading...`.

### `build_reload_plan` — the exact diff (UPSTREAM `config_reload.rs:122-260`)

| Change | Bucket | Message |
|---|---|---|
| `api_listen` | **restart** | `api_listen changed: {old} -> {new}` |
| `api_key` | **restart** | `api_key changed` |
| `network_enabled` | **restart** | `network_enabled changed` |
| `network` | **restart** | `network config changed` |
| `memory` | **restart** | `memory config changed` |
| `home_dir` / `data_dir` | **restart** | `home_dir changed: … -> …` |
| `vault` | **restart** | `vault config changed` |
| `default_model` | hot | `HotAction::UpdateDefaultModel` — **updated in-place, no restart** |
| `channels` | hot | `ReloadChannels` (also re-reads `secrets.env`) |
| `usage_footer` | hot | `UpdateUsageFooter` |
| `web` / `browser` | hot | `ReloadWebConfig` / `ReloadBrowserConfig` |
| `approval` | hot | `UpdateApprovalPolicy` |
| `max_cron_jobs` | hot | `UpdateCronConfig` |
| `webhook_triggers` | hot | `UpdateWebhookConfig` |
| `extensions` | hot | `ReloadExtensions` |
| `mcp_servers` | hot | `ReloadMcpServers` |
| `a2a` | hot | `ReloadA2aConfig` |
| `fallback_providers` | hot | `ReloadFallbackProviders` |
| `provider_urls` | hot | `ReloadProviderUrls` |
| `provider_api_keys` | **no-op** | `provider_api_keys changed (takes effect on next driver init)` |
| `log_level` / `language` / `mode` | no-op | `log_level: info -> debug` etc. |

**`default_model` IS hot-reloadable** — a natural assumption to get backwards. `[memory]` is not.

### The silent gap — the real trap

`build_reload_plan` **never inspects**: `bindings`, `budget`, `exec_policy`, `auth`, `tts`,
`docker`, `pairing`, `heartbeat`, `skills`, `users`, `thinking`, `auto_reply`, `canvas`, `oauth`,
`broadcast`, `media`, `links`, `workspaces_dir`, `workflows_dir`, `auth_profiles`, `reload`.

**Editing any of them produces `config reload: no changes detected` and no effect whatsoever until
a full restart.** The log actively tells you nothing happened *and* nothing needed to happen — both
wrong. If you change `[budget]`, `[heartbeat]`, `[[bindings]]`, `[auth]` or `[exec_policy]`,
**restart the daemon; do not trust hot-reload.**

### Reload validators (UPSTREAM `config_reload.rs:277-303`)

Only four checks run before a reload is applied:

```rust
if config.api_listen.is_empty()          → "api_listen cannot be empty"
if config.max_cron_jobs > 10_000         → "max_cron_jobs exceeds reasonable limit (10000)"
if let Err(e) = config.approval.validate() → "approval policy: {e}"
if config.network_enabled && config.network.shared_secret.is_empty()
                                         → "network_enabled is true but network.shared_secret is empty"
```

**That is the entire validation surface.** No model check, no provider check, no key check, no
channel check. A config naming a nonexistent provider validates clean.

`should_apply_hot`: `off`→never, `restart`→never (caller must restart), `hot`/`hybrid`→apply if any
hot action. Other strings: `Config hot-reload: no actionable changes`, `config reload requested via
API` (`no_changes` | `partial` | `hot_actions_applied`). API-triggered reload is UNVERIFIED — daemon down.

---

## 9. The `include` directive (undocumented)

UPSTREAM `crates/openfang-kernel/src/config.rs:1-4, 126-235`:

> Supports config includes: the `include` field specifies additional TOML files to load and
> deep-merge before the root config (**root overrides includes**).

```toml
include = ["providers.toml", "channels.toml"]   # MUST be an array of strings
```

- Paths are **relative to the root config's directory**.
- `const MAX_INCLUDE_DEPTH: u32 = 10;` — includes may nest; each nested file resolves relative to
  its own directory.
- Merge order: `include[0]` → `include[1]` → … → **root last (root wins)**.
- `deep_merge_toml`: tables merge recursively; **everything else — including arrays — is
  wholesale replaced by the overlay.** So a root `[[fallback_providers]]` does not append to an
  included one, it **replaces the entire array**.
- The `include` key is stripped from the tree before deserialization (and from each included file).

### Security rules (all enforced in `resolve_config_includes`)

| Input | Result |
|---|---|
| absolute path | `Config include rejects absolute path: {p}` |
| any `..` component | `Config include rejects path traversal: {p}` |
| resolves outside config dir (symlink) | `Config include '{p}' escapes config directory` |
| unreadable / missing | `Config include '{p}' cannot be resolved: {e}` |
| already visited | `Circular config include detected: {p}` |
| depth > 10 | `Config include depth exceeded maximum of 10` |
| bad TOML inside | `Failed to parse config include '{p}': {e}` |

**Any one of these aborts the WHOLE include pass — every include is discarded and the daemon
continues on the root config alone**, logging only:

```
Config include resolution failed, using root config only
```

It is a `warn!`, not a fatal. A typo in one include silently drops all of them.

### `doctor`'s include check is naive and disagrees with the loader — SUSPECT

VERIFIED, four cases:

```bash
$ printf 'api_listen="127.0.0.1:9999"\ninclude=["extra.toml"]\n' > $H/config.toml
$ OPENFANG_HOME=$H openfang doctor | grep -i include
  ✔ Include file: extra.toml                      # ok        (loader: ok)

$ # include=["nope.toml"]
  ✘ Include file not found: nope.toml             # fail      (loader: fail)

$ # include=["/etc/passwd"]
  ✔ Include file: /etc/passwd                     # ok  <-- WRONG. Loader REJECTS absolute paths.

$ # include=["../escape.toml"]
  ✘ Include file not found: ../escape.toml        # fail, but for the wrong reason (it just doesn't exist)
```

**`doctor` only checks existence — it does not apply the absolute-path, traversal, escape, circular
or depth rules.** It green-lights `/etc/passwd`, which the loader refuses. And `config_deser`
stays `ok` in every case, because include failure is non-fatal:

```bash
$ OPENFANG_HOME=$H openfang doctor --json | jq -c '.checks[]|select(.check|test("include|deser"))'
# include=["extra.toml"]  → {"check":"config_deser","status":"ok"} {"check":"config_includes","count":1,"status":"ok"}
# include=["nope.toml"]   → {"check":"config_deser","status":"ok"} {"check":"config_includes","count":1,"status":"fail"}
# include=["/etc/passwd"] → {"check":"config_deser","status":"ok"} {"check":"config_includes","count":1,"status":"ok"}
```

**Never use `doctor` to validate includes.** Settle it by grepping the daemon log after restart for
`Loading config include` (one INFO per successfully loaded file) vs
`Config include resolution failed, using root config only`.

This install does **not** use `include`. `config_includes` is absent from its doctor output.

---

## 10. Sections that look live but are inert here

- **`[budget]`** — `max_hourly_usd` / `max_daily_usd` / `max_monthly_usd` (0.0 = unlimited),
  `alert_threshold` = 0.8, `default_max_llm_tokens_per_hour` = 0 (when >0, **overrides every
  agent's own limit**). SEED: `/api/budget` all 0.0 and every `usage_events.cost_usd = 0.0`,
  because `custom_models.json` has `input_cost_per_m = 0.0` for gonka/NIM. **Budget enforcement is
  therefore inert regardless of what you set here** — cost is always computed as 0. The only real
  throttle is `agent.toml`'s `max_llm_tokens_per_hour`. Also **not diffed by hot-reload** (§8).
- **`[heartbeat] default_timeout_secs`** — default 180, doc-comment: *"Set higher to prevent idle
  hands from being marked as crashed."* UPSTREAM #1252: the value is **ignored** and 60s is
  hardcoded on a path; SEED VERIFIED both `timeout_secs=180` (3134×) and `timeout_secs=60` (139×)
  in the logs. **Raising this will not fully stop the Crashed→auto-recovery cycle.** Also not diffed.
- **`[vault]`** — `enabled = true` by default, but auto-detected from `vault.enc` existing. Not
  initialized here (§11).
- **`[auth]`** — dashboard login, `enabled = false`. If you set `password_hash` to anything that is
  not an Argon2id PHC string the daemon warns: `Dashboard auth password_hash is not in Argon2id
  format. Login will fail. Regenerate with: openfang auth hash-password`.

---

## 11. The vault

VERIFIED — uninitialized on this install:

```bash
$ openfang vault list
Vault not initialized. Run: openfang vault init
```

```
openfang vault init          # Initialize the credential vault
openfang vault set <KEY>     # KEY = the env var name
openfang vault list          # values hidden
openfang vault remove <KEY>
```

UPSTREAM `crates/openfang-extensions/src/vault.rs`. Binary strings (VERIFIED):

```
Credential vault initialized at
Vault key (save this as
Using existing vault key from OS keyring
Vault master key stored in OS keyring
Vault already exists. Delete it first to re-initialize.
Vault not initialized. Run `openfang vault init`.
Unrecognized vault file format
openfang-vault / openfang-vault-v1
unlock with vault key or OPENFANG_VAULT_KEY env var
```

- File: `~/.openfang/vault.enc` (override via `[vault] path`). Format tag `openfang-vault-v1`.
- Master key is stored in the **OS keyring** under service `openfang-vault`; `OPENFANG_VAULT_KEY`
  is the headless/CI escape hatch.
- **`openfang add <name> --key <K>` claims to store the key in the vault.** With the vault
  uninitialized this path is UNVERIFIED here — do not assume `add --key` persists anything until
  `vault init` has run.
- **`[vault]` changes are restart-required** (`vault config changed`).
- **Machine note:** this user's login keyring is a keys-keeper vault with 75 secrets. `vault init`
  will write into that keyring. Do not run it casually.

**Config/secrets do not read from the vault.** `api_key_env` / `bot_token_env` resolve from the
process env (populated by `.env` + `secrets.env`), not the vault. The vault serves
extensions/integrations and the `vault_*` tools. Two independent secret stores.

---

## 12. `OPENFANG_*` and related env vars

Complete list from the binary (VERIFIED — `strings -n 6 BIN | grep -oE 'OPENFANG_[A-Z0-9_]+' | sort -u`):

| Var | Effect |
|---|---|
| `OPENFANG_HOME` | **Home dir override. The only working config redirect.** `openfang_home()` checks it before `~/.openfang`. Also honoured by the `.env`/`secrets.env` loader. |
| `OPENFANG_API_KEY` | API key. Referenced by `API key required for non-loopback requests. Set OPENFANG_API_KEY or bind to 127.0.0.1.` |
| `OPENFANG_LISTEN` | Listen address override. |
| `OPENFANG_ALLOW_NO_AUTH` | Permits an unauthenticated non-loopback bind. **Do not set.** |
| `OPENFANG_URL` | Client-side daemon URL (CLI/WhatsApp gateway target). |
| `OPENFANG_DEFAULT_AGENT` | Default agent for one-shot commands. |
| `OPENFANG_AGENTS_DIR` | Agent manifest dir override. |
| `OPENFANG_AGENT_ID` | Agent id for the current context (also exported to skill subprocesses alongside `PYTHONPATH`/`VIRTUAL_ENV`). |
| `OPENFANG_MESSAGE` | One-shot message payload. |
| `OPENFANG_VAULT_KEY` | Vault master key — bypasses the OS keyring. §11. |
| `OPENFANG_WEBHOOK_TOKEN` | **Default value of `[webhook_triggers] token_env`.** Token must be ≥32 chars. |
| `OPENFANG_AGENT_TOOL_TIMEOUT_SECS` | Per-agent tool timeout. |
| `OPENFANG_TOOL_TIMEOUT_SECS` | Global tool timeout. |
| `OPENFANG_SUBPROCESS_TIMEOUT_SECS` | Subprocess turn timeout. **Wins over `default_model.subprocess_timeout_secs` at driver-construction time** (UPSTREAM doc-comment, `types/config.rs:1690-1697`). Honoured only by `provider = "claude-code"`; other providers accept the field and ignore it. |
| `OPENFANG_ENABLE_PARAKEET_MLX` | Apple-silicon STT backend. Irrelevant on this x86 host. |

Non-`OPENFANG_` vars the binary reads: `OLLAMA_BASE_URL`, `OLLAMA_HOST`, `OLLAMA_API_KEY`,
`LMSTUDIO_HOST` (0.6.8+), `WHATSAPP_GATEWAY_PORT`, `RUST_LOG`, `COMPUTERNAME` (vault keyring id).

`RUST_LOG` works for scoping config diagnostics (VERIFIED):

```bash
RUST_LOG=openfang_kernel::config=debug openfang doctor --json 2>&1 | grep -i include
```

### Provider key env vars

**Convention: `{PROVIDER_UPPER}_API_KEY`**, applied automatically when `api_key_env` is unset
(UPSTREAM `types/config.rs`, `provider_api_keys` doc-comment). Override per-provider with either:

```toml
[default_model]
api_key_env = "GONKA_1_API_KEY"      # explicit, per model config — what this install uses

[provider_api_keys]
nvidia = "NVIDIA_API_KEY"            # provider id -> env var NAME; NOT hot-reloadable
```

**The convention breaks on hyphenated provider ids** — `gonka-1` → `GONKA-1_API_KEY`, which is not a
legal shell identifier. **Any provider id containing a hyphen MUST set `api_key_env` explicitly.**
This install does. Do not remove those lines.

Names doctor recognizes (and nothing else): `GROQ_API_KEY` `OPENROUTER_API_KEY` `ANTHROPIC_API_KEY`
`OPENAI_API_KEY` `DEEPSEEK_API_KEY` `GEMINI_API_KEY` `GOOGLE_API_KEY` `TOGETHER_API_KEY`
`MISTRAL_API_KEY` `FIREWORKS_API_KEY` `AWS_BEARER_TOKEN_BEDROCK`. Also seen in the binary:
`PERPLEXITY_API_KEY`.

Channel key env vars checked by doctor: `TELEGRAM_BOT_TOKEN` `DISCORD_BOT_TOKEN` `SLACK_APP_TOKEN`
`SLACK_BOT_TOKEN`. Runtime errors: `TELEGRAM_BOT_TOKEN not set`, `SLACK_BOT_TOKEN not set`,
`DISCORD_BOT_TOKEN not set`. Other adapters resolve their own `*_env` keys from `[channels.<name>]`
(44 adapters compiled in; `channel list` shows only 8 — `/api/channels` is the truth).

---

## 13. Recipes

**Safe read of the live config:**
```bash
openfang config show                      # raw file (no validation!)
openfang config get default_model.model   # parsed single value, exit 1 if broken
```

**Validate before restarting (the only real gate):**
```bash
openfang config get api_listen >/dev/null || echo "SYNTAX ERROR — do not restart"
openfang doctor --json | jq '.checks[]|select(.check=="config_deser")'   # type errors only
# Remember: neither catches a misspelled key/section.
```

**Guard against the silent-default disaster — assert your intent survived the parse:**
```bash
for kv in default_model.provider=gonka-1 default_model.model=moonshotai/kimi-k2.6 api_listen=127.0.0.1:4200; do
  k=${kv%%=*}; want=${kv#*=}; got=$(openfang config get "$k" 2>&1)
  [ "$got" = "$want" ] && echo "ok   $k=$got" || echo "DRIFT $k: want=$want got=$got"
done
```

**Edit safely (comments preserved):**
```bash
cp -a ~/.openfang/config.toml ~/.openfang/config.toml.bak-$(date +%Y%m%d-%H%M%S)
$EDITOR ~/.openfang/config.toml          # hand-edit; NOT `config set`
openfang config get api_listen >/dev/null && echo "parses OK"
```

**Sandbox any experiment — never `--config`:**
```bash
H=$(mktemp -d); cp ~/.openfang/config.toml $H/
OPENFANG_HOME=$H openfang config set log_level debug
OPENFANG_HOME=$H openfang doctor --json | jq '.all_ok'
```

**Post-restart config triage:**
```bash
grep -E 'using defaults|using root config only|Loaded configuration|Migrating misplaced|Loading config include' \
  ~/.openfang/daemon-start.log | tail -20
# "Loaded configuration" = good. Any "using defaults" = you are running anthropic/claude-sonnet-4.
```

---

## Not in this file

- **`[[fallback_models]]`, `[model]`, `[capabilities]`, `[resources]`, `[schedule]`, `[autonomous]`,
  `[[required_env]]`, `[[tools.provided]]`, `[[settings]]`, `[requires]`** — these are
  **`agents/<name>/agent.toml`** (manifest) keys, not `config.toml`. The SEED's "Config schema
  (discovered)" list conflates the two; most of those sections are **silently ignored** in
  `config.toml` (§4). See the agents reference.
- Model catalog / `custom_models.json` / `models` CLI → models reference.
- Channel adapter specifics → channels reference.
- Cron/trigger/workflow schemas → automation reference.

## Open questions (SUSPECT / UNVERIFIED — daemon down)

| Question | How to settle |
|---|---|
| Does `GET /api/config` expose the **merged** (include-resolved) config? Only observable path if `include` is used. | Start daemon, `curl -s 127.0.0.1:4200/api/config \| jq`, compare to `config show`. |
| Does `GET /api/config/schema` return a machine-readable schema? String exists in the binary. | `curl -s 127.0.0.1:4200/api/config/schema`. |
| API-triggered reload (`config reload requested via API` → `no_changes`/`partial`/`hot_actions_applied`) — which endpoint/verb? | Would need a POST; **forbidden read-only**. |
| Does UPSTREAM #1195 (namespace stripping on custom base_url) bite `moonshotai/kimi-k2.6` on `provider="gonka-1"`? Reported scoped to `provider="openai"`; it works here. | Grep daemon log for the outbound model string during a live request. |
| Is `[[bindings]]` used at all in a single-user install? `lenient_extract_bindings` implies a real routing surface. | `curl -s 127.0.0.1:4200/api/config \| jq .bindings`; log line `binding_index` / `survivors` (`config.rs:311,329`). |
