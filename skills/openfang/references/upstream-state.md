# OpenFang upstream: abandoned at v0.6.9 (and what that means)

**Read this when** you are about to say "let's upgrade", "let's file an issue", "wait for a fix", or
"check if this is a known bug" — and before any decision about the long-term future of this install.

---

## The headline

**The upstream project is dead, and it died on the exact version you run.**

| Fact | Value |
|---|---|
| Repo | https://github.com/RightNow-AI/openfang |
| Stars / forks | ~18 000 / ~2 300 |
| **Last commit to `main`** | **2026-05-12** (`acf2587e` "bump v0.6.9") |
| **Latest release** | **v0.6.9, 2026-05-12** |
| Installed here | **v0.6.9** — the last release *is* the last commit |
| Open issues | ~108 (≈70 issues + ≈38 PRs), including security reports |
| Sole committer | `jaberjaber23` |
| License | Apache-2.0 per the API; repo carries both `LICENSE-APACHE` and `LICENSE-MIT` |
| Homepage | https://www.openfang.sh/ (still live) |

The repo's `pushed_at` looks recent — **ignore it**. It only reflects Dependabot branches
(`dependabot/cargo/axum-0.8.9` and friends). `main` has not moved since May.

Two open, **maintainer-unanswered** issues say the quiet part out loud:
- [#1240](https://github.com/RightNow-AI/openfang/issues/1240) "Is Openfang still an active project?" (2026-06-08)
- [#1214](https://github.com/RightNow-AI/openfang/issues/1214) "Still maintained?" (2026-05-26)

Everything filed after 2026-05-12 has **zero maintainer response** — including the security set.

The README already told us, before it went quiet:

> *"feature complete but still pre-1.0. Expect rough edges and breaking changes between minor
> versions. Pin to a specific commit for production use until v1.0."*

**Marker:** VERIFIED (repo state checked via `gh` on 2026-07-14).

---

## What this means for us — read this twice

1. **No fix is coming for anything in `gotchas.md`.** Every workaround in this playbook is
   **permanent**, not a stopgap. Stop framing them as "until upstream fixes it".
2. **Do not file issues.** Nobody is reading them. Record the finding here instead.
3. **Do not wait for a release.** v0.6.9 is terminal. There is no upgrade path within OpenFang.
4. **The open security issues stay open forever** (WASM memory limits, the WhatsApp gateway). Treat
   them as permanent properties of the software and design around them — see `channels.md`.
5. **`CHANGELOG.md` is stale** — it stops at 0.5.10 with an empty `[Unreleased]`. The real notes live
   only on the GitHub Releases page. Never cite the CHANGELOG.

---

## LibreFang — the successor

**https://github.com/librefang/librefang** — "LibreFang, Libre Agent Operating System".

| Fact | Value |
|---|---|
| Stars | ~335 |
| Latest release | **v2026.7.11** (2026-07-10) |
| Activity | pushed the same day this was written |
| Scale | 24 crates, 2 100+ tests |
| Docs | https://docs.librefang.ai · site https://librefang.ai · live demo https://flyio.librefang.ai |
| Relationship | a **detached re-upload**, not a GitHub fork; adds i18n and CI |

It surfaced in #1240 — a *contributor* (`houko`), not the maintainer, pointed at it.

**Marker:** VERIFIED (repo state checked 2026-07-14).

### Honest migration assessment

**What we know:** it is alive, it releases, it has far more tests than upstream ever showed, and it
is where any fix to the bugs below would land.

**What we do NOT know — do not pretend otherwise:**
- Whether it is config-compatible with our `config.toml` / `agent.toml` / `custom_models.json`.
- Whether the SQLite schema (v5, 8 migrations) migrates cleanly, or at all.
- Whether any of our specific pain points (#1252 heartbeat, #1206 schedules, #1212 embeddings) are
  actually fixed there.
- Whether our gonka + NIM provider setup works unchanged.
- Its governance and bus factor. 335 stars and a young project is not obviously more durable than an
  18k-star project that just died.

**Recommendation:** treat migration as a *project*, not a command. Before moving: read their docs on
config and storage, check their issue tracker for our five bug numbers, and dry-run against a copied
`OPENFANG_HOME` — never against the live one. Do not migrate because "upstream is dead" alone; the
current install works.

---

## The 0.6.x release history

100 tags, `v0.1.0` (2026-02-24) → `v0.6.9` (2026-05-12). Note the shape: **0.6.5 through 0.6.9 all
shipped on a single day, 2026-05-12** — a maintainer clearing the decks before going quiet.

| Version | Date | What shipped |
|---|---|---|
| 0.6.0 | 04-19 | cron fan-out delivery (channel/webhook/file/email); skill config injection via `SKILL.md` frontmatter; unified 32-command slash registry; atomic `config.toml` writer |
| 0.6.1 | 04-29 | 12 fixes: heartbeat exempts idle reactive agents (#1102); router keyed on `user_id` not `channel_id` (#1120); configurable claude-code subprocess timeout; `media.audio_base_url` |
| 0.6.2 | 04-29 | SSRF unification; `exec_policy.mode="full"` actually applies (#1132); Telegram errors propagate (#1100); MCP stdio gets `HOME`/`TMP` (#1095) |
| 0.6.3 | 05-01 | **reasoning models retain state across turns** (#1098); Slack `envelope_id` dedup; subprocess timeout hot-reload |
| 0.6.4 | 05-01 | Firefox sidebar; OpenRouter free repointed to tool-capable models; fish/CachyOS installer |
| 0.6.5 | 05-12 | `agent_activate`; `cloneAgent`; server-assigned `msg_id`; Telegram `user_id` surfaced (#915) |
| 0.6.6 | 05-12 | vLLM 0.19 `reasoning` field; Discord images; `create_directory`; LaTeX/KaTeX |
| 0.6.7 | 05-12 | WS reconnect; agent uninstall; Stop deactivates hand; `shell_env_passthrough`; TTS/image base URLs |
| 0.6.8 | 05-12 | workspace `state_dir` split; WS auth aligned; skill tools; Requesty; `OLLAMA_HOST`/`LMSTUDIO_HOST`; Telegram `message_thread_id` (#780) |
| 0.6.9 | 05-12 | **security only** — rustls-webpki 0.103.13 (RUSTSEC-2026-0104/0098/0099), wasmtime 43.0.2 (RUSTSEC-2026-0114), `cargo fmt` |

**Marker:** UPSTREAM (GitHub Releases page).

---

## Repo structure

Cargo workspace, 14 crates (13 code + `xtask`), ~137K LOC, one ~66 MB binary. Dependency flow
downward:

```
openfang-cli → openfang-desktop → openfang-api → openfang-kernel
    ├── openfang-runtime    agent loop, 3 LLM drivers, 23 tools, WASM, MCP, A2A
    ├── openfang-channels   44 adapters, router, bridge, rate limiter
    ├── openfang-wire       OFP p2p, HMAC-SHA256
    ├── openfang-migrate    OpenClaw YAML→TOML
    └── openfang-skills     60+ bundled skills, ClawHub
openfang-memory   SQLite substrate (schema v5), semantic search, usage
openfang-types    shared types; all config structs use #[serde(default)]
```
Plus `openfang-hands` and `openfang-extensions` (present in `crates/`, omitted from the upstream
architecture diagram).

The `#[serde(default)]` on every config struct is the mechanism behind a nasty behaviour documented
in `config-reference.md`: a malformed config **silently degrades to defaults** instead of refusing to
start.

**Marker:** UPSTREAM (repo tree + `docs/architecture.md`).

---

## Issue index — the ones that matter to an operator

Sorted by what they cost you.

### Costs money / burns quota

| Issue | Title | Impact |
|---|---|---|
| [#1252](https://github.com/RightNow-AI/openfang/issues/1252) | `[heartbeat] default_timeout_secs` ignored, hardcoded 60s | Idle/reactive agents get flagged `Crashed` regardless of config → continuous auto-recovery, each firing an LLM call. Reporter measured **~570 provider calls/day of pure idle churn**. **VERIFIED here**: logs carry both `timeout_secs=180` and `timeout_secs=60`, plus a real `Unresponsive Running agent marked as Crashed for recovery agent=ops` → `Auto-recovering crashed agent (attempt 1/3)` loop. Filed 2026-06-22, unanswered. Note 0.6.1's #1102 was supposed to fix this class and evidently did not. |
| [#1206](https://github.com/RightNow-AI/openfang/issues/1206) | Sample agent configs ship aggressive default schedules | Unexpected LLM cost. **VERIFIED here**: `agents/ops/agent.toml` ships `periodic = { cron = "every 5m" }` = 288 runs/day. Audit all 30 `agent.toml` schedules. |

### Breaks memory / leaks data

| Issue | Title | Impact |
|---|---|---|
| [#1212](https://github.com/RightNow-AI/openfang/issues/1212) | Embedding driver hardcodes 6 cloud providers; `base_url` ignored for the `openai` driver | Self-hosted embedding servers unreachable without forking. **Worse:** chat can route locally while embedding-recall silently goes to OpenAI cloud — content leak + credit burn. Our `embedding_provider = "ollama"` path is the one that works. See `memory-embeddings.md`. |
| [#1251](https://github.com/RightNow-AI/openfang/issues/1251) | Embedding `base_url` force-appends `/v1` with no opt-out | `http://host:8004/v3` becomes `/v3/v1`. |

### Model / provider config

| Issue | Title | Impact |
|---|---|---|
| [#1195](https://github.com/RightNow-AI/openfang/issues/1195) | OpenAI-compatible custom `base_url` strips the namespace from slashed model IDs | `openai/gpt-oss-120b` → `gpt-oss-120b` → `model_not_found`. Scoped to `provider = "openai"`. **Relevant to us**: our default is `moonshotai/kimi-k2.6` — a slashed ID on a custom `base_url`, the same shape. Related: #856. |
| [#1154](https://github.com/RightNow-AI/openfang/issues/1154) | LM Studio / Ollama localhost-only in `init` | Partly mitigated by the `OLLAMA_HOST` / `LMSTUDIO_HOST` / `VLLM_HOST` / `LEMONADE_HOST` overrides added in 0.6.8. |

### Concurrency / automation

| Issue | Title | Impact |
|---|---|---|
| [#1230](https://github.com/RightNow-AI/openfang/issues/1230) / [#795](https://github.com/RightNow-AI/openfang/issues/795) | A single agent processes requests **serially** | No parallel per-session execution. Both open. |
| [#1192](https://github.com/RightNow-AI/openfang/issues/1192) | Deleted workflow reappears after daemon restart | TOML/DB dual-source-of-truth, same family as #1087/#1132. |
| [#1253](https://github.com/RightNow-AI/openfang/issues/1253) | Workflow `collect` joins pre-fan-out outputs instead of only the preceding fan-out group | Wrong results from fan-out workflows. |
| [#1204](https://github.com/RightNow-AI/openfang/issues/1204) | `shell_exec` hard-capped at 120s | Long commands truncate. |

### Security — all open, all unanswered post-abandonment

| Issue | Title |
|---|---|
| [#1232](https://github.com/RightNow-AI/openfang/issues/1232) / [#1233](https://github.com/RightNow-AI/openfang/issues/1233) / [#1234](https://github.com/RightNow-AI/openfang/issues/1234) | WhatsApp gateway: no auth gateway↔API, no auth on its HTTP API, wildcard CORS, untrusted content forwarded to the LLM |
| [#1242](https://github.com/RightNow-AI/openfang/issues/1242) | WASM `max_memory_bytes` configured but **never enforced** (no Store limiter set) |
| [#1241](https://github.com/RightNow-AI/openfang/issues/1241) | WASM watchdog threads accumulate under load |
| [#1235](https://github.com/RightNow-AI/openfang/issues/1235) | RUSTSEC-2026-0097 `rand` unsoundness across three versions in the tree |

### Misc

[#1256](https://github.com/RightNow-AI/openfang/issues/1256) 64 KB file upload limit ·
[#1254](https://github.com/RightNow-AI/openfang/issues/1254) GHCR pull 401 unauthenticated ·
[#1184](https://github.com/RightNow-AI/openfang/issues/1184) MCP bridge Windows stubbed ·
[#866](https://github.com/RightNow-AI/openfang/issues/866) page refresh during streaming loses in-progress state

### A note on `parallel_tool_calls`

There is **no `parallel_tool_calls` knob anywhere** — not in the repo source, not as a string in the
installed binary (VERIFIED). Parallelism exists at two other levels:

- **Workflow fan-out is real** — `docs/workflows.md`: *"The engine collects all consecutive `fan_out`
  steps and launches them simultaneously using `futures::future::join_all`."* (subject to #1253).
- **`max_concurrent_tools`** is documented in `docs/agent-templates.md` and set in every bundled
  `agent.toml` (5–10) — but code search finds it **only** in docs, sample manifests, and the TUI
  display, with no hits in `openfang-runtime` or `openfang-kernel`.
  **Marker: SUSPECT** — strongly suggests a parsed-but-inert knob. What would settle it: reading the
  `openfang-runtime` source for a read of that field. GitHub code search can be incomplete, so this
  is suggestive, not proven. Do not rely on it to throttle anything.

Practical consequence for us: when gonka rejected parallel tool-calls, there was **no setting to turn
them off** — the only fix was changing the model. See `models-providers.md`.

---

## Useful upstream docs (still online)

- **Architecture — the best single read:** https://github.com/RightNow-AI/openfang/blob/main/docs/architecture.md
- Configuration: `docs/configuration.md` · `openfang.toml.example`
- Providers: `docs/providers.md` · Channels: `docs/channel-adapters.md` · Workflows: `docs/workflows.md`
- Troubleshooting: `docs/troubleshooting.md` · Production checklist: `docs/production-checklist.md`
- Docs site: https://openfang.sh/docs · hands: https://openfang.sh/docs/hands
- **The real changelog:** https://github.com/RightNow-AI/openfang/releases
- Third-party: unofficial docs mirror https://github.com/mudrii/openfang-docs · memory-system
  reverse-engineering writeup https://github.com/breath57/how-ai-agents-remember

**Read upstream docs with suspicion.** They describe intent, not this build — `max_concurrent_tools`
above is the cautionary example. When docs and the binary disagree, the binary wins.

---

## Distribution

Install is via `curl https://openfang.sh/install | sh`, GHCR images, and Tauri `.dmg`/`.msi` release
artifacts. **UNVERIFIED:** whether the crates are published to crates.io — every query returned an
API data-access block (likely the VPN egress IP), and nothing in the repo suggests publication.
