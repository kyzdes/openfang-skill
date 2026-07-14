# OpenFang Agents — authoritative reference (v0.6.9)

**Read this when:** writing or editing an `agent.toml`; creating an agent (`agent new` / `agent spawn`);
changing an agent's model, tools, shell allowlist, schedule, or budget; debugging why a manifest edit
"did nothing"; explaining `[capabilities]` / RBAC; explaining how the system prompt is built from
SOUL/IDENTITY/AGENTS/BOOTSTRAP/MEMORY/USER/TOOLS/HEARTBEAT; or diagnosing `Boot failed: ... Missing API key`.

Scope: the agent domain only. Providers/models → `models-providers.md`. Daemon lifecycle → `daemon-lifecycle.md`.

**Two routing corrections, because this file is where the wrong answers live:**
- **"Run on a timer AND post the result somewhere" → `automation.md` (cron), NOT `[schedule]`.**
  `[schedule]` has **no delivery**. See [`[schedule]`](#schedule--the-cost-centre).
- **"Make agent Y use model X" → [Pin a model to ONE agent](#pin-a-model-to-one-agent) in this file.**
  `models-providers.md` Recipe B switches the **global** default and moves all 30 agents. `pinned_model` is
  inert. Register the model itself with `models-providers.md` Recipe A first.

Evidence tags: **VERIFIED** = observed on this install (command + real output shown) · **UPSTREAM** = read from
`RightNow-AI/openfang@main` (= v0.6.9 = installed build; file + line cited) · **SUSPECT** = contradictory
evidence · **UNVERIFIED** = could not test.

---

## The seven things that waste the most time

1. **`[schedule]` HAS NO DELIVERY.** It fires an agent turn on a timer and the output goes **nowhere but the
   WebSocket** — no Telegram, no email, no webhook. If your task is *"run every N minutes and post the result
   somewhere"*, `[schedule]` is the **wrong section of the wrong file** and will silently burn tokens forever
   while posting nothing. **Delivery lives in the cron subsystem → `automation.md`.**
   See [`[schedule]` — the cost centre](#schedule--the-cost-centre).
2. **`provider` and `model` must BOTH be `"default"` for inheritance to happen.** The check is
   `is_default_provider && is_default_model` — an `&&`, not an `||`. Setting `model = "kimi-k2.6"` while
   leaving `provider = "default"` means **no overlay runs**, `"default"` is passed to the driver factory as a
   literal provider name, and you get `Unknown provider 'default'`. UPSTREAM `crates/openfang-kernel/src/kernel.rs:1634-1638`.
   To point one agent at one model, use [Pin a model to ONE agent](#pin-a-model-to-one-agent) — **not**
   `pinned_model`, which is inert (item 6).
3. **`max_concurrent_tools` is not a schema field. It is silently ignored.** Every bundled manifest sets it;
   it does not exist in `ResourceQuota`. See [the inert-key trap](#resources--budgets).
4. **Editing `agent.toml` only takes effect if a field in the kernel's `changed` list differs.** `temperature`,
   `max_tokens`, `[[fallback_models]]`, and every `[capabilities]` key **except `tools`** are not in that list.
   See [TOML vs DB](#toml-on-disk-vs-db--what-actually-reloads).
5. **`agent chat`, `agent kill` and `cron create` need a UUID. `chat`, `message`, `memory`, `sessions` take a name.**
   ⚠️ `cron create` was listed on the name side here until 2026-07-14 — **wrong**. Its `--help` says
   `Agent name or ID to run` and is lying; the kernel `parse_str`s it. `automation.md` #3 owns this.
   See [addressing](#addressing-uuid-vs-name).
6. **`pinned_model` and `[routing]` are inert. Do not reach for them.** Neither is in the boot `changed` diff,
   so setting either **alone is silently ignored forever**. A root key literally named `pinned_model` is the
   obvious thing to grab when told "make this agent use this model" — it is the wrong answer. Use
   [`[model]`](#pin-a-model-to-one-agent).
7. **Long `SOUL.md` is wasted.** It is capped at **1000 chars** and its code blocks are stripped. `AGENTS.md`
   caps at 2000; `IDENTITY.md`/`USER.md`/`MEMORY.md` at 500 each. Only `[model] system_prompt` is uncapped.
   See [the cap table](#prompt-assembly--the-cap-table).

---

## Layout — two directories, different jobs

```
~/.openfang/agents/<name>/agent.toml        # MANIFEST — the only file here. Source of truth.
~/.openfang/workspaces/<name>/              # RUNTIME state + prompt context files
```

VERIFIED — both hold exactly the same 30 names:

```bash
ls /home/kyzdes/.openfang/agents/ | wc -l      # 30
ls /home/kyzdes/.openfang/workspaces/ | wc -l  # 30
```

The 30: `analyst architect assistant code-reviewer coder customer-support data-scientist debugger devops-lead
doc-writer email-assistant health-tracker hello-world home-automation legal-assistant meeting-assistant ops
orchestrator personal-finance planner recruiter researcher sales-assistant security-auditor social-media
test-engineer translator travel-planner tutor writer`

VERIFIED workspace contents (`ls -la ~/.openfang/workspaces/assistant/`):

```
AGENT.json  AGENTS.md  BOOTSTRAP.md  HEARTBEAT.md  IDENTITY.md  MEMORY.md  SOUL.md  TOOLS.md  USER.md
data/  logs/  memory/  output/  sessions/  skills/
```

`HEARTBEAT.md` exists in **1 of 30** workspaces (assistant only). The other 7 `.md` files exist in all 30.
VERIFIED: `cd ~/.openfang/workspaces && ls */*.md | sed 's|.*/||' | sort | uniq -c` → `30` for each of
USER/TOOLS/SOUL/MEMORY/IDENTITY/BOOTSTRAP/AGENTS, `1` for HEARTBEAT.

`AGENT.json` is a pointer, not config. VERIFIED:

```json
{
  "created_at": "2026-07-13T21:34:23.768687547+00:00",
  "state_dir": "/home/kyzdes/.openfang/workspaces/assistant",
  "workspace": "/home/kyzdes/.openfang/workspaces/assistant"
}
```

Agent private state is **always** name-based under `~/.openfang/workspaces/<name>/`, even if the manifest sets a
`workspace` elsewhere — so `SOUL.md` and per-agent memory survive recreation and are never dumped into a
user-supplied workspace path (UPSTREAM `kernel.rs:1692-1699`, issue #1097). `state_dir` and `workspace` are
separate manifest keys precisely because of this split (0.6.8).

---

## Manifest schema — every key

Authoritative source: UPSTREAM `crates/openfang-types/src/agent.rs:425-518` (`struct AgentManifest`).

`AgentManifest` carries `#[serde(default)]` at struct level and **no `deny_unknown_fields`**.
**Unknown keys are silently accepted and dropped — a typo never errors.** This is how
`max_concurrent_tools` survives in 15 shipped manifests while doing nothing.

### Root keys

| Key | Type | Default | Notes |
|---|---|---|---|
| `name` | string | `"unnamed"` | Identity for `chat`/`message`/`memory`; workspace dir name. |
| `version` | string | `"0.1.0"` | Cosmetic. |
| `description` | string | `""` | Shown in `agent list`; injected into the prompt if `system_prompt` is empty. |
| `author` | string | `""` | Cosmetic. All 30 bundled = `"openfang"`. |
| `module` | string | `"builtin:chat"` | All 30 bundled use `builtin:chat`. Also WASM / Python agent modules. |
| `tags` | array | `[]` | Cosmetic. Present in 20 of 30. |
| `priority` | enum | `Normal` | **`Low`/`Normal`/`High`/`Critical` — capitalized.** No `rename_all`, unlike every other enum here. `priority = "normal"` fails to parse → whole `[…]` falls back to default. |
| `profile` | enum | none | `minimal`/`coding`/`research`/`messaging`/`automation`/`full`/`custom`. **Capability escalation shortcut — see below.** |
| `skills` | array | `[]` | Skill names. |
| `mcp_servers` | array | `[]` | MCP server names. |
| `metadata` | table | `{}` | Free-form. |
| `pinned_model` | string | none | Bypasses `[routing]`. Log: `Stable mode: using pinned model`. **NOT in the boot diff → setting it alone is silently ignored forever. Not the way to pin a model to an agent — see [Pin a model to ONE agent](#pin-a-model-to-one-agent).** |
| `workspace` | path | none | Working dir for file tools. Not where state lives. |
| `state_dir` | path | none | Defaults to `~/.openfang/workspaces/<name>/`. |
| `generate_identity_files` | bool | **`true`** | Set `false` to stop OpenFang creating the 8 `.md` files on spawn. |
| `tool_allowlist` | array | `[]` | Post-filter over granted tools. |
| `tool_blocklist` | array | `[]` | Post-filter. Log: `Agent tool filters updated`. |
| `cache_context` | bool | `false` | **Not provider prompt caching.** Freezes the first read of `context.md` — see below. |
| `max_history_messages` | int | **`20`** | `DEFAULT_MAX_HISTORY_MESSAGES`. `Some(0)` is coerced back to 20 (`effective_max_history_messages`, `agent.rs:527-534`). |
| `exec_policy` | table | inherits config | The real shell gate — see [capabilities](#capabilities--the-security-boundary). |
| `routing` | table | none | `[routing]` — `simple_model`/`medium_model`/`complex_model`/`simple_threshold`/`complex_threshold`. **NOT in the boot diff → inert unless a diffed field also changes. See [`pinned_model` and `[routing]`](#pinned_model-and-routing--real-subsystem-inert-config).** |

### `[model]`

**This is the per-agent model override, and the only working one.** Task is "make agent Y use model X"? →
[Pin a model to ONE agent](#pin-a-model-to-one-agent). Registering the model itself, the global default, the
fallback chain, and the provider catalog are `models-providers.md`'s job — not duplicated here.

UPSTREAM `agent.rs:372-403`. Struct-level `#[serde(default)]`.

| Key | Default | Notes |
|---|---|---|
| `provider` | `"anthropic"` | `"default"` → inherit (with `model`). |
| `model` | `"claude-sonnet-4-20250514"` | **`#[serde(alias = "name")]` — `name = "…"` inside `[model]` also works.** |
| `max_tokens` | `4096` | |
| `temperature` | `0.7` | |
| `system_prompt` | `"You are a helpful AI agent."` | **Uncapped** in the prompt. The one place to put long instructions. |
| `api_key_env` | none | **A hint, not a lock.** See below. |
| `base_url` | none | Inherited from `[default_model]` only when the overlay runs. |

Note the defaults: an `agent.toml` with **no `[model]` section at all** points at `anthropic` /
`claude-sonnet-4-20250514` / `ANTHROPIC_API_KEY`, not at your `[default_model]`. **Omitting `[model]` is not
the same as `provider = "default"`.** You must write the section and say `"default"` twice.

### The `"default"` inheritance rule — exact

UPSTREAM `kernel.rs:1627-1659`, spawn path:

```rust
let is_default_provider = manifest.model.provider.is_empty() || manifest.model.provider == "default";
let is_default_model    = manifest.model.model.is_empty()    || manifest.model.model    == "default";
if is_default_provider && is_default_model {
    // overlay [default_model]: provider, model, then api_key_env / base_url ONLY IF unset
    if !dm.api_key_env.is_empty() && manifest.model.api_key_env.is_none() { … }
    if dm.base_url.is_some() && manifest.model.base_url.is_none() { … }
}
```

Consequences an operator must internalize:

- **Both-or-nothing.** Half-defaulting disables the overlay entirely.
- **A hot-reloaded `default_model_override` beats boot-time config** (`kernel.rs:1639-1646`).
- **On spawn, a manifest `api_key_env` WINS** over `[default_model].api_key_env` (the `is_none()` guard).
- **On boot-restore, it LOSES** — `kernel.rs:1436-1439` assigns `api_key_env` unconditionally, no `is_none()`
  guard. **The same manifest resolves to a different `api_key_env` depending on whether it was spawned or
  restored.** UPSTREAM; the divergence is visible in the two code paths.
- The restore path has an extra clause: an agent named `assistant` **whose description is exactly
  `"General-purpose assistant"`** is force-updated to `[default_model]` even if it pinned a provider
  (`kernel.rs:1428-1430`). This install's assistant description is
  `"General-purpose assistant agent. The default OpenClaw agent for everyday tasks…"` — **not** an exact
  match, so the clause does **not** fire here. VERIFIED (`grep '^description' ~/.openfang/agents/assistant/agent.toml`).
- After the overlay, the model catalog normalizes aliases and strips the provider prefix
  (`kernel.rs:1661-1683`). Related: upstream #1195 (custom `base_url` strips the namespace from slashed model
  IDs when `provider = "openai"`). This install's `moonshotai/kimi-k2.6` on a custom `base_url` has the same
  shape but `provider = "gonka-1"`, outside #1195's scope.

### `api_key_env` is a hint, not a lock

The upstream comment at `kernel.rs:1629-1632` says it outright: *"even if the agent manifest specifies an
api_key_env (which is just a hint about which env var to check, not a hard lock on provider/model)"*.

At driver-construction time (UPSTREAM `crates/openfang-runtime/src/drivers/mod.rs:525-565`) the fallback chain is:

1. `config.api_key` (resolved from `api_key_env`), else
2. the **provider's canonical** env var from the `provider_defaults()` table, else
3. for an unknown provider with a `base_url`: the convention `{PROVIDER_UPPER}_API_KEY`
   (`-` → `_`) — this is exactly how `provider = "gonka-1"` finds `GONKA_1_API_KEY` on this install.

**This is why the stale `api_key_env` in the 11 `[model]` blocks is mostly harmless here:** the
lookup misses, and step 3 recovers via `GONKA_1_API_KEY`. **All 11** — 8× `GEMINI_API_KEY` *and* 3×
`DEEPSEEK_API_KEY` (`architect`, `orchestrator`, `security-auditor`) — are covered by this verdict.
*(It used to say "8 bundled manifests", silently excluding the three DEEPSEEK agents from its own
conclusion — and `orchestrator` is one of the 4 scheduled agents.)* VERIFIED — zero `GEMINI`/`DEEPSEEK` rows in the
audit trail: `sqlite3 ~/.openfang/data/openfang.db "SELECT detail,COUNT(*) FROM audit_entries WHERE detail LIKE '%GEMINI%' OR detail LIKE '%DEEPSEEK%' GROUP BY detail LIMIT 5;"` → empty.

Canonical env vars (UPSTREAM `drivers/mod.rs:97+`, `provider_defaults()`) — note the aliases:

| provider (and aliases) | env var | key required |
|---|---|---|
| `groq` | `GROQ_API_KEY` | yes |
| `gemini` \| `google` | `GEMINI_API_KEY` | yes |
| `openai` | `OPENAI_API_KEY` | yes |
| `deepseek` | `DEEPSEEK_API_KEY` | yes |
| `openrouter` / `requesty` / `together` / `mistral` / `fireworks` / `perplexity` / `cohere` | `<NAME>_API_KEY` | yes |
| `ollama` / `vllm` / `lmstudio` / `lemonade` | `<NAME>_API_KEY` | **no** |
| `github-copilot` \| `copilot`, `claude-code`, `azure` \| `azure-openai`, `vertex-ai` \| `vertex` \| `google-vertex` | special drivers | — |

Unknown provider + no `base_url` → verbatim error:
`Unknown provider '<x>'. Supported: anthropic, gemini, openai, azure, bedrock, groq, openrouter, deepseek, together, mistral, fireworks, ollama, vllm, lmstudio, perplexity, cohere, ai21, cerebras, sambanova, huggingface, xai, replicate, github-copilot, chutes, venice, nvidia, codex, claude-code. Or set base_url for a custom OpenAI-compatible endpoint.`

Unknown provider + key set + no `base_url` → verbatim:
`Provider '<x>' has API key (<X>_API_KEY is set) but no base_url configured. Add base_url to your [default_model] config or set it in [provider_urls].`

### Pin a model to ONE agent

The per-agent counterpart to `models-providers.md` Recipe A (register a model) / Recipe B (switch the
**global** default). **Recipe B moves all 30 agents including the production Telegram bot — this section is
what you want when the task is "use model X for agent Y".** Register the model first (`models-providers.md`
Recipe A, one `custom_models.json` entry **per provider alias**); this section only points an agent at it.

**Write BOTH keys, both concrete.** That is the whole trick, and it follows from the `&&` rule above:

```toml
# ~/.openfang/agents/<name>/agent.toml
[model]
provider = "gonka-1"                        # concrete — NOT "default"
model    = "zai-org/GLM-5.1"                # concrete — NOT "default"
base_url = "https://api.gonkagate.com/v1"   # see the base_url note below
# do NOT set api_key_env — the convention resolves gonka-1 -> GONKA_1_API_KEY
```

Why each line:

- **Both concrete, or neither.** `provider = "default"` + a concrete `model` skips the overlay and passes the
  literal `"default"` to the driver factory → `Unknown provider 'default'`. There is no "inherit the provider,
  override just the model" mode. UPSTREAM `kernel.rs:1627-1659`.
- **It reloads.** `model.provider` and `model.model` are both in the boot `changed` diff, so this edit lands on
  restart. (`base_url` and `api_key_env` are *not* diffed — but the merge is total once any diffed field moves,
  so they ride along in the same edit. See [TOML vs DB](#toml-on-disk-vs-db--what-actually-reloads).)
- **No `api_key_env`.** For an unknown provider with a `base_url`, driver construction falls through to the
  convention `{PROVIDER_UPPER}_API_KEY` (`-`→`_`). That is how `gonka-1` finds `GONKA_1_API_KEY` here.
  See [`api_key_env` is a hint, not a lock](#api_key_env-is-a-hint-not-a-lock).
- **`base_url`: SUSPECT — set it.** When you pin a concrete provider the overlay does **not** run, so
  `base_url` is **not** inherited from `[default_model]`. `[provider_urls]` maps `gonka-1` →
  `https://api.gonkagate.com/v1` (VERIFIED: `sed -n '/\[provider_urls\]/,/^$/p' ~/.openfang/config.toml` → 5
  entries) and *should* make the name resolvable, but nothing confirms the **agent** driver path consults
  `[provider_urls]` rather than only `[default_model]`. Setting it in the agent block is redundant-at-worst
  here because it is the same URL. **Settled by:** pin an agent to a provider that is in `[provider_urls]`,
  omit `base_url`, restart, and grep the boot log for `Provider '<x>' has API key (<X>_API_KEY is set) but no
  base_url configured.` — its presence proves `[provider_urls]` is not consulted on this path.

**Verify from the boot log, not `models list`.** `openfang models list` prints only the builtin catalog and
never shows a custom model; `--provider gonka-1` returns an empty table rather than an error. The catalog-count
line and `✔ Kernel booted (…)` are the only proof. Details and the exact greps: `models-providers.md`.

**Two things nobody warns you about at the point of use — say them to the user out loud:**

1. **Pinning permanently freezes that agent's undiffed fields.** Today `changed` is true for all 30 agents on
   every boot *only because* disk says `provider = "default"` while the DB holds the post-overlay `"gonka-1"`.
   Write a concrete provider and that mismatch disappears, the agent's diff goes quiet, and its **undiffed**
   fields — `temperature`, `max_tokens`, `capabilities.shell`, `[[fallback_models]]` — freeze at their DB
   values and every future edit to them is silently ignored until the agent is deleted and recreated. This is
   an unavoidable, permanent cost of pinning, not a bug you can work around. **Get `temperature` and
   `max_tokens` right in the same edit.** See [TOML vs DB](#toml-on-disk-vs-db--what-actually-reloads).
2. **The pinned agent's fallback chain still serves the OLD model.** Index 0 is your pinned model; indices 1+
   come from `config.toml`'s **global** `[[fallback_providers]]` (VERIFIED here: gonka-2/3/4 on
   `moonshotai/kimi-k2.6`, then nim-1 on `meta/llama-3.3-70b-instruct`). One 502 from your pinned provider and
   the agent quietly answers on kimi while you believe it is on the new model, with no "fell back" line at
   `log_level = "info"`. You **cannot** fix this per-agent without moving everyone: the config fallbacks are
   global, and agent-level `[[fallback_models]]` is not in the boot diff (below). Chain mechanics and the
   `driver_index` census: `models-providers.md`.

**`api_key_env` across a key boundary — SETTLED 2026-07-14 by experiment. NOT a fuse. Cross-family
pinning is safe.** This was the project's longest-standing open hazard: the fear was that the restore
path assigns `api_key_env` unconditionally (`kernel.rs:1436-1439`), so a restart would force-overwrite
a pinned agent's key to `GONKA_1_API_KEY` and **send a gonka key to NVIDIA**.

**It does not.** Pinned `hello-world` (never-used template, 0 usage events, no schedule) to
`provider = "nim-1"` / `model = "meta/llama-3.3-70b-instruct"` / `api_key_env = "NIM_1_API_KEY"`,
restarted, sent one real message:

- the manifest survived the restart **untouched** (`grep -E "provider|api_key_env" agent.toml` → both
  still `nim-1` / `NIM_1_API_KEY`);
- the call **succeeded** — a gonka key against NVIDIA would have 401/403'd;
- `usage_events` recorded `hello-world | meta/llama-3.3-70b-instruct | in=9397 | out=22` — the only
  such call in the install's history, so it provably reached NIM and authenticated.

**The assignment sits INSIDE the `is_default_provider && is_default_model` guard.** A pinned agent
never enters that block. The old "prefer the same key family until settled" rule is **obsolete — do
not reintroduce it.** `models-providers.md` (Recipe C) is the owner of the cross-family procedure.

**Still required:** write `provider`, `model` **and** `api_key_env` together. The guard is an `&&`,
so a half-pin (`model` only) leaves the literal string `"default"` as the provider name and the
driver fails **lazily, on first use** — see `models-providers.md`.

> **Cross-file note (2026-07-14).** `models-providers.md` once listed this under "Non-traps — do not
> waste time on these", asserting the assignment sits *inside* the guard and cross-family pinning is
> therefore safe. **That assertion has been withdrawn**; both files now agree this is SUSPECT and
> unresolvable read-only. **This file is the owner.** Do not let any text talk you out of checking it.

**Do NOT use `pinned_model` or `[routing]` for this** — see below.

### `pinned_model` and `[routing]` — real subsystem, inert config

Both are real root manifest keys and both are live code. VERIFIED — the strings are in the binary:

```bash
strings -n 4 ~/.openfang/bin/openfang | grep -cF 'Stable mode: using pinned model'   # 1
strings -n 4 ~/.openfang/bin/openfang | grep -cF 'Model routing applied'             # 1
strings -n 4 ~/.openfang/bin/openfang | grep -cF 'pinned_model'                      # 1
```

`[routing]` (`simple_model` / `medium_model` / `complex_model` / `simple_threshold` / `complex_threshold`)
picks a model per turn by estimated complexity; `pinned_model` bypasses that and logs
`Stable mode: using pinned model`.

**Neither is in the boot `changed` diff.** Setting `pinned_model` or `[routing]` **alone** in a manifest is
therefore **silently ignored forever** — no error, no log line, no effect. Zero of the 30 bundled manifests use
either (VERIFIED: `grep -l 'pinned_model\|^\[routing\]' ~/.openfang/agents/*/agent.toml` → no matches).

**UNVERIFIED:** the value format (bare model id vs `provider/model`), how `pinned_model` interacts with
`[model] model`, and whether it survives if you *do* force a reload by touching a diffed field. Nothing in the
playbook exercises this path and no agent here has ever used it. **Settled by:** set `pinned_model` plus a
`description` change (a diffed field) on a throwaway agent, restart, and grep the boot log for
`Stable mode: using pinned model`.

**Operator rule: to make one agent use one model, write `[model] provider` + `[model] model`
([above](#pin-a-model-to-one-agent)). `pinned_model` is a trap that looks like the answer.**

### `[[fallback_models]]`

UPSTREAM `agent.rs:406-415`. Fields: `provider` (required), `model` (required), `api_key_env`, `base_url`.
`"default"` resolves the same way per entry (`kernel.rs:5700-5710`).

Beware the naming collision: **agent manifests use `[[fallback_models]]`; `config.toml` uses
`[[fallback_providers]]`.** VERIFIED — `grep -c fallback_providers ~/.openfang/config.toml` → `4`;
`grep -h '^\[\[' ~/.openfang/agents/*/agent.toml | sort | uniq -c` → `22 [[fallback_models]]`.

VERIFIED distribution across the 30 installed manifests
(`grep -h api_key_env ~/.openfang/agents/*/agent.toml | sort | uniq -c`):

```
     19 api_key_env = "GEMINI_API_KEY"
     11 api_key_env = "GROQ_API_KEY"
      3 api_key_env = "DEEPSEEK_API_KEY"
```

Split by section (VERIFIED via awk over each file): **11 in `[model]`** (8× GEMINI: analyst, code-reviewer,
coder, data-scientist, debugger, legal-assistant, researcher, test-engineer; 3× DEEPSEEK: architect,
orchestrator, security-auditor) and **22 in `[[fallback_models]]`** (11× GEMINI, 11× GROQ).

🔴 **Correction — this section used to say "Only `assistant` names a real fallback model". That is
FALSE, and it contradicted the line directly above it** (which counts "11× GEMINI" in
`[[fallback_models]]` — those are exactly these 11). **11 of 30 agents name a concrete
`gemini-2.0-flash`**, VERIFIED by section-attributing awk over all 30 manifests:

```
assistant  customer-support  devops-lead  doc-writer  email-assistant  meeting-assistant
planner    recruiter         sales-assistant          social-media     writer
```

The remaining 11 `[[fallback_models]]` blocks are `provider = "default"`, `model = "default"` — i.e.
they fall back to *the same model that just failed*, only re-resolved.

⚠️ **This matters when you pin one of those 11** (including `assistant`, the Telegram-facing one):
after pinning, **index 1 is a model whose key does not exist** in `secrets.env`. Edit that
`[[fallback_models]]` block in the **same restart** as the `[model]` block — afterwards the diff goes
quiet and it is frozen. → `models-providers.md` Recipe C.

The conclusion below ("treat them as decorative") still holds — those 11 would fail anyway for lack
of a `GEMINI_API_KEY` — but it was previously reached from a premise that was wrong for 11 of 30
agents.

```toml
# assistant/agent.toml — one of the 11 concrete fallbacks
[[fallback_models]]
provider = "default"
model = "gemini-2.0-flash"
api_key_env = "GEMINI_API_KEY"
```

```toml
# coder/agent.toml — representative of the other 21: a no-op fallback
[[fallback_models]]
provider = "default"
model = "default"
api_key_env = "GROQ_API_KEY"
```

**Treat the shipped `[[fallback_models]]` blocks as decorative.** They provide no resilience on this install.

---

## The GROQ trap — what actually happened (the seed's causal story is wrong)

The verbatim, greppable error:

```
error: Boot failed: Agent LLM driver init failed: Missing API key: Set GROQ_API_KEY environment variable for provider 'groq'
```

VERIFIED count and blast radius:

```bash
sqlite3 ~/.openfang/data/openfang.db \
  "SELECT agent_id, COUNT(*) FROM audit_entries WHERE outcome LIKE '%GROQ%' GROUP BY agent_id;"
# 91c689c2-…  97   (orchestrator)
# cbbfb77e-…  38   (ops)
# c08fae4f-…   3   (health-tracker)
```

138 rows, and **exactly the three scheduled agents** — orchestrator (`continuous`, 120 s), ops
(`periodic every 5m`), health-tracker (`periodic every 1h`). Nothing else ever fired because nothing else runs
unprompted.

**The common belief — that the manifests' `api_key_env = "GROQ_API_KEY"` caused this — is wrong.**
Disproof, VERIFIED: `health-tracker/agent.toml` contains **no `api_key_env` and no `[[fallback_models]]` at
all** (`grep -nE 'api_key_env|fallback' ~/.openfang/agents/health-tracker/agent.toml` → only
`provider = "default"` / `model = "default"`), yet it produced the `provider 'groq'` error. And the error text
is generated from `provider_defaults(provider).api_key_env` (UPSTREAM `drivers/mod.rs:532-535`) — it names the
**resolved provider's canonical** env var, never the manifest's.

The real cause: **`[default_model]` itself was `groq` during that window**, and `provider = "default"`
faithfully inherited it. The timeline is decisive, VERIFIED:

```bash
sqlite3 ~/.openfang/data/openfang.db \
  "SELECT MIN(timestamp),MAX(timestamp),COUNT(*) FROM audit_entries WHERE outcome LIKE '%GROQ_API_KEY%';"
# 2026-07-13T16:17:54 | 2026-07-13T19:29:54 | 138      <- stops dead
sqlite3 ~/.openfang/data/openfang.db \
  "SELECT MIN(timestamp),MAX(timestamp),COUNT(*) FROM audit_entries WHERE outcome LIKE '%nvidia%';"
# 2026-07-13T22:01:26 | 2026-07-14T08:33:25 | 237      <- current config's failure mode takes over
```

The GROQ errors **ceased permanently** once `[default_model]` was pointed at `gonka-1`. They are **historical,
not live**. The live failure mode on this install is the NIM last-resort fallback being unreachable.

Operator rule: **`Missing API key … for provider 'X'` names the *resolved* provider. Go read
`[default_model]` in `config.toml`, not the agent's `api_key_env`.**

SUSPECT — the precise value `[default_model]` held before 19:29 is unrecoverable: all four `config.toml.bak*`
files already contain `gonka-1` (VERIFIED: `grep -A5 default_model ~/.openfang/config.toml.bak`), and no
`ConfigChange` audit rows exist in that window. `ModelConfig::default()` and `DefaultModelConfig::default()`
are both `anthropic`/`claude-sonnet-4-20250514` (UPSTREAM `agent.rs:391-402`, `config.rs:1701-1711`), so the
groq value came from `openfang init`/wizard, matching the tiers in `docs/agent-templates.md`. **Settled by:**
an `openfang init` into a throwaway `OPENFANG_HOME` and reading the generated `[default_model]`.

---

## `[capabilities]` — the security boundary

UPSTREAM `agent.rs:578-601` (`struct ManifestCapabilities`). All 30 bundled manifests declare it.

### 🚨 An OMITTED `tools` array is FAIL-OPEN — it grants ALL 65 tools. VERIFIED 2026-07-14.

**This is the single most dangerous defaulting behaviour in OpenFang.** The intuitive guess (an
omitted array = `[]` = deny-all) is **wrong and backwards**.

Method: removed the `tools = […]` line from `hello-world`'s `[capabilities]` (leaving `network`,
`memory_*`, and even `agent_spawn = false` in place), restarted, sent one real message, read the
`Tools selected for LLM request` log line:

```
# BEFORE — tools = ["file_read","file_list","web_fetch","web_search","memory_store","memory_recall"]
tool_count=6

# AFTER — the tools line deleted
tool_count=65   ← every tool, including shell_exec, docker_exec, process_start,
                  agent_spawn, agent_kill, file_write, browser_run_js
```

A 6-tool sandboxed agent became a **full-shell, container-spawning, agent-killing** agent by
**deleting one line.** And note: `agent_spawn = false` was still in the manifest, yet `agent_spawn`
appeared in the granted set — **the per-capability flags do not save you once `tools` is omitted.**

✅ **Rule, now VERIFIED not merely prudent: `[capabilities].tools` MUST be an explicit allowlist on
every agent.** Never omit it. An omitted `tools` is a silent privilege escalation to the full toolset
— and combined with `network = ["*"]` and a channel anyone can message, that is a remote shell.
On this install all 30 bundled manifests declare `tools` explicitly, so nothing is currently exposed
— but a hand-written or migrated manifest that drops the line is wide open with no warning.

🔶 **Still UNVERIFIED — the *scope* arrays (`memory_read`/`memory_write`/`network`).** The experiment
above settled `tools` only. Whether an omitted `memory_read` defaults to `[]` (deny) or `["*"]`
(allow) was not tested — it needs an agent that exercises a scoped memory op. Given `tools` is
fail-open, **assume the scope arrays are too until proven otherwise, and declare them all.**

| Key | Type | Semantics |
|---|---|---|
| `tools` | array | Tool IDs the agent may call. |
| `network` | array | Allowed hosts, e.g. `["api.openai.com:443"]`. |
| `memory_read` | array | Memory scopes. |
| `memory_write` | array | Memory scopes. |
| `agent_spawn` | **bool** | Not a list. |
| `agent_message` | array | Name patterns. |
| `shell` | array | Command patterns. |
| `ofp_discover` | bool | Discover remote agents over OFP. |
| `ofp_connect` | array | Peer patterns. |

VERIFIED presence across the 30
(`grep -hE '^(tools|network|memory_read|memory_write|agent_message|agent_spawn|shell) *=' ~/.openfang/agents/*/agent.toml | sed 's/=.*//' | sort | uniq -c`):

```
      5 agent_message      2 agent_spawn     30 memory_read     30 memory_write
     18 network           13 shell           30 tools
```

`ofp_discover` / `ofp_connect`: **0 of 30**.

**UNVERIFIED — does cron `delivery_targets` need a `channel_send`-ish tool in `capabilities.tools`?** Almost
certainly **no**: the fan-out runs kernel-side *after* the agent turn returns, so it never passes through agent
RBAC — but that is an inference from the code layout, not an observed fact, and if it is wrong the failure is
silent (a WARN at a log level nobody reads). Do not add speculative tools to a manifest to "be safe"; that
widens the security boundary for nothing. **Settled by:** create a cron job with a `delivery_targets` channel
entry against an agent whose `tools` list has no channel/send tool, run it once with the daemon up, and check
whether the message arrives. Contract and fan-out semantics: `automation.md`.

### Glob semantics — the prefix-match trap

UPSTREAM `crates/openfang-types/src/capability.rs:189-212`. `glob_matches` is 20 lines and handles exactly
four shapes: `*` (everything), exact equality, `*suffix` (`ends_with`), `prefix*` (`starts_with`), and
`prefix*suffix`. There is **no path awareness, no shell awareness, no character classes.**

**`shell = ["git *"]` compiles to `cmd.starts_with("git ")` against the whole command string.**
`git status; rm -rf ~` starts with `git ` — so this layer passes it. Same for `network`: `"*"` is granted to
**18 of 30** bundled agents, including every one that also has `shell`.

The mitigation is a **second, independent gate**: `exec_policy`. Both must pass.

### `exec_policy` — the gate that actually stops shell

UPSTREAM `crates/openfang-types/src/config.rs:940-1013`.

```
ExecSecurityMode:
  Deny       (aliases: "none", "disabled")   — block all shell execution
  Allowlist  (alias:  "restricted")          — DEFAULT — only safe_bins + allowed_commands
  Full       (aliases: "allow","all","unrestricted") — everything (unsafe, dev only)
```

`ExecPolicy::default()`: `mode = Allowlist`, **`allowed_commands = []`**, `timeout_secs = 30`,
`max_output_bytes = 102400`, `no_output_timeout_secs = 30`, `shell_env_passthrough = []`, and
`safe_bins = ["sleep","true","false","cat","sort","uniq","cut","tr","head","tail","wc","date","echo","printf","basename","dirname","pwd","env"]`.

**This install has no `[exec_policy]` anywhere.** VERIFIED: `grep -c exec_policy ~/.openfang/config.toml` → `0`;
`grep -c exec_policy ~/.openfang/agents/*/agent.toml` → `0` for all 30. So every agent runs
`mode = Allowlist` with an **empty `allowed_commands`** — meaning `capabilities.shell = ["cargo *", "git *", …]`
grants **nothing beyond the 18 stdin-only `safe_bins`**. Declaring `shell` in a manifest is necessary but not
sufficient.

Verbatim errors, greppable:

```
'<cmd>' is not in the exec allowlist. Add it to exec_policy.allowed_commands or exec_policy.safe_bins.
'<cmd>' (inside shell wrapper) is not in the exec allowlist. Add it to exec_policy.allowed_commands or exec_policy.safe_bins.
Current exec_policy.mode = '<mode>'. To allow shell commands, set exec_policy.mode = 'full' in the agent manifest or config.toml.
Current exec_policy.mode = '<mode>'. To allow this command, add it to exec_policy.allowed_commands or set exec_policy.mode = 'full'.
```

The **`(inside shell wrapper)`** variant is the important one: `exec_policy` decomposes `sh -c "a; b"` and
checks each binary. That is what contains the `git *` prefix-match hole above. **Never rely on
`capabilities.shell` alone as a security boundary — it is a prefix match. `exec_policy` is the boundary.**

`exec_policy` resolution on boot (UPSTREAM `kernel.rs:1385-1407`): if the manifest on disk does **not**
override it, the agent is re-assigned `config.exec_policy` on every restore — deliberately, so a cached value
from an earlier boot cannot pin the agent to a stale mode. Log line: `Agent exec_policy resolved`.

Also relevant: `shell_env_passthrough`. Subprocesses run with `env_clear()` and receive only
`SAFE_ENV_VARS` (PATH, HOME, TMPDIR, LANG, TERM…). A single entry of `"*"` forwards **everything** —
**this leaks `GONKA_1_API_KEY`, `TELEGRAM_BOT_TOKEN`, and every other secret in `secrets.env` into child
processes.** Never set it.

Related: `--yolo` auto-approves all tool calls including `shell_exec` for all 30 agents. Do not use it.

### `profile` — a capability escalation shortcut

UPSTREAM `agent.rs:299-370` + `kernel.rs:6757-6790` (`manifest_to_capabilities`).

**`profile` only expands when `capabilities.tools` is EMPTY.** If `tools` is set, the profile's tool list is
ignored (other capability fields still merge, with explicit manifest values winning).

| profile | tools granted |
|---|---|
| `minimal` | `file_read`, `file_list` |
| `coding` | `file_read`, `file_write`, `file_list`, `shell_exec`, `web_fetch` |
| `research` | `web_fetch`, `web_search`, `file_read`, `file_write` |
| `messaging` | `agent_send`, `agent_list`, `memory_store`, `memory_recall` |
| `automation` | the above ten combined |
| `full` / `custom` | **`["*"]`** |

`implied_capabilities()` then **derives** the rest: any `web_*` ⇒ `network = ["*"]`; `shell_exec` ⇒
`shell = ["*"]`; any `agent_*` ⇒ `agent_spawn = true` **and** `agent_message = ["*"]`; any `memory_*` ⇒
`memory_read = ["*"]`. `memory_write` is always `["self.*"]`.

**`profile = "full"` with no `[capabilities]` grants `tools=["*"]`, `network=["*"]`, `shell=["*"]`,
`agent_spawn=true`, `agent_message=["*"]`, `memory_read=["*"]` in one word.** And the dashboard's built-in
spawn templates ship `profile = "full"` (VERIFIED, `strings ~/.openfang/bin/openfang | grep -oE 'profile = "[a-z]+"' | sort | uniq -c` → `2 profile = "full"`, `2 profile = "coding"`, `1 profile = "research"`,
`1 profile = "automation"`). **Zero of the 30 on-disk manifests use `profile`** — they enumerate `tools`
explicitly. Prefer their approach. `exec_policy` still gates the resulting `shell = ["*"]`.

### Real examples

```toml
# ops — narrowest shell, read-mostly
[capabilities]
tools = ["shell_exec", "file_read", "file_list"]
memory_read = ["*"]
memory_write = ["self.*"]
shell = ["docker *", "git *", "cargo *", "systemctl *", "ps *", "df *", "free *"]
# note: no `network` key at all
```

```toml
# orchestrator — the only agent that can spawn and write anywhere
[capabilities]
tools = ["agent_send", "agent_spawn", "agent_list", "agent_kill", "memory_store", "memory_recall", "file_read", "file_write"]
memory_read = ["*"]
memory_write = ["*"]          # the ONLY agent with unrestricted memory_write
agent_spawn = true
agent_message = ["*"]
```

```toml
# security-auditor — tightest shell allowlist on the box
shell = ["cargo audit *", "cargo tree *", "git log *"]
```

```toml
# hello-world — explicit denial
agent_spawn = false
```

---

## `[resources]` — budgets

UPSTREAM `agent.rs:249-282` (`struct ResourceQuota`), `#[serde(default)]`.

| Key | Default | Real? |
|---|---|---|
| `max_llm_tokens_per_hour` | `0` = **unlimited** | **Yes — the only budget that bites on this install.** |
| `max_memory_bytes` | `268435456` (256 MB) | WASM only. Upstream #1242: **never enforced**. |
| `max_cpu_time_ms` | `30000` | WASM. |
| `max_tool_calls_per_minute` | `60` | Rate limit. |
| `max_network_bytes_per_hour` | `104857600` (100 MB) | |
| `max_cost_per_hour_usd` | `0.0` = unlimited | Inert here — every `usage_events.cost_usd` is `0.0` because gonka/NIM have `input_cost_per_m = 0.0` in `custom_models.json`. |
| `max_cost_per_day_usd` | `0.0` | idem |
| `max_cost_per_month_usd` | `0.0` | idem |

**The inert-key trap — `max_concurrent_tools` does not exist.** It appears in **15 of 30** bundled manifests
(VERIFIED: `grep -h '^max_' ~/.openfang/agents/*/agent.toml | sort | uniq -c` → `12 max_concurrent_tools = 5`,
`3 max_concurrent_tools = 10`). It is **not a field of `ResourceQuota`** — VERIFIED
`grep -c max_concurrent_tools` over upstream `agent.rs` → **`0`**. Upstream code search returns **17 hits, all
of them docs, sample `agent.toml`s, and `crates/openfang-cli/src/tui/screens/agents.rs` (display only)** —
**zero in `openfang-runtime` or `openfang-kernel`**:

```bash
gh api "search/code?q=max_concurrent_tools+repo:RightNow-AI/openfang" --jq '.total_count, (.items[]|.path)'
# 17
# docs/agent-templates.md
# agents/coder/agent.toml
# crates/openfang-cli/src/tui/screens/agents.rs
# agents/email-assistant/agent.toml … (all remaining hits are agents/*/agent.toml)
```

Because `AgentManifest` has no `deny_unknown_fields`, serde drops it in silence. **This closes the seed's
SUSPECT #30: `max_concurrent_tools` is parsed-and-discarded, confirming why `max_concurrent_tools = 10` never
prevented gonka's `ResourceExhausted: Worker local total request limit reached (40/16)`.** Use
`max_tool_calls_per_minute` — the real key.

`apply_budget_defaults(&config.budget, &mut manifest.resources)` runs on **both** spawn (`kernel.rs:1690`) and
restore (`kernel.rs:1410-1413`), so `config.toml`'s `default_max_llm_tokens_per_hour` fills unset quotas.

VERIFIED spread: `max_llm_tokens_per_hour` is set in all 30 — `500000` (orchestrator), `300000` (assistant),
`200000` ×8, `150000` ×14, `120000` ×1, `100000` ×4, `50000` (ops).

---

## `[schedule]` — the cost centre

> ### STOP — `[schedule]` has NO DELIVERY. If you want the output sent anywhere, you are in the wrong file.
>
> `[schedule]` fires an agent turn on a `background.rs` timer and the result goes **only to the WebSocket**.
> There is no delivery target, no `max_fires`, no per-job disable, and no way to stop it without editing the
> TOML and restarting the daemon. An agent with `[schedule] periodic = { cron = "every 30m" }` and no cron job
> **burns tokens 48×/day and posts nothing, forever, with no error.**
>
> | Your task | Right mechanism |
> |---|---|
> | "run every N min **and post to Telegram / a channel**" | **cron subsystem → `automation.md`** (`delivery_targets` fan-out). Leave `[schedule]` out of the manifest entirely. |
> | "wake up periodically to update its own memory / internal state, output unused" | `[schedule]` — this section |
> | "run when a message arrives" | nothing — `Reactive` is the default |
>
> **Pick exactly ONE.** `[schedule]` and a cron job are unrelated code paths that share the word "schedule";
> setting both gives you **two independent timers = 2× the runs and 2× the spend**, only one of which
> delivers. The `schedule_create` agent tool is also not a way out — it hardcodes `"delivery": {"kind":"none"}`.
>
> The cron dialect differs too: `[schedule]` wants `every 30m`; the cron API wants `*/30 * * * *`. Each is
> silently wrong in the other's slot (see `automation.md`). Cross-checked against `automation.md`; the
> `[schedule]`-has-no-delivery split is VERIFIED there.

UPSTREAM `agent.rs:225-247` (`enum ScheduleMode`, `rename_all = "snake_case"`). Default: **`Reactive`** — wake
only on a message/event. **26 of 30 agents have no `[schedule]` and never run unprompted.**

VERIFIED — the only four (`grep -l '^\[schedule\]' ~/.openfang/agents/*/agent.toml`):

```toml
# ops             — 288 runs/day. Upstream #1206.
[schedule]
periodic = { cron = "every 5m" }

# health-tracker  — 24 runs/day
[schedule]
periodic = { cron = "every 1h" }

# orchestrator    — 720 runs/day
[schedule]
continuous = { check_interval_secs = 120 }

# security-auditor
[schedule]
proactive = { conditions = ["event:agent_spawned", "event:agent_terminated"] }
```

- `check_interval_secs` defaults to **60**, not 120 (`default_check_interval()`, `agent.rs:243-245`).
- An unparseable cron silently becomes 300 s: log `Unparseable cron expression, defaulting to 300s`.
- Loop log lines: `Periodic loop: sending scheduled prompt`, `Continuous loop: sending self-prompt`,
  `Continuous loop: skipping tick (busy)`.
- **These four are the entire autonomous LLM spend.** They are why the 138 GROQ rows exist and why 60 calls
  burned 487,508 input vs 4,351 output tokens (112:1) mostly concluding "No actionable items". **If the user
  wants to stop background spend, delete `[schedule]` from these four manifests — nothing else ticks.**

Note the seed lists `assistant` among the scheduled agents. **That is wrong.** VERIFIED:
`grep -l '^\[schedule\]' ~/.openfang/agents/*/agent.toml` returns exactly `ops`, `orchestrator`,
`health-tracker`, `security-auditor`. `assistant` has no `[schedule]`; it has `[autonomous]`, which is a
different key (below), and `HEARTBEAT.md`.

## `[autonomous]`

UPSTREAM `agent.rs:71-83` (`struct AutonomousConfig`, `#[serde(default)]`).

| Key | Notes |
|---|---|
| `max_iterations` | Agent-loop iteration cap. Verbatim runtime hint: `Configure a higher limit in agent.toml under [autonomous] max_iterations` |
| `max_restarts` | Supervisor restart budget. |
| `quiet_hours` | Optional string. |
| `heartbeat_interval_secs` | |
| `heartbeat_channel` | Optional channel name. |

VERIFIED: **1 of 30** manifests has `[autonomous]` — `assistant`, with `max_iterations = 100`, and it is the
only agent with a `HEARTBEAT.md`. That is not a coincidence: **`HEARTBEAT.md` is injected only when
`is_autonomous`** (see below).

---

## Prompt assembly — the cap table

UPSTREAM `crates/openfang-runtime/src/prompt_builder.rs:76-220` (`build_system_prompt`). Sections are emitted
in this order and joined with `\n\n`. **This is the whole truth about what your markdown files do.**

| # | Section | Source | Cap | Skipped for subagent? | Condition |
|---|---|---|---|---|---|
| 1 | Agent Identity | `[model] system_prompt`, else `"You are {name}…" + description` | **none** | no | always |
| 1.5 | `## Current Date` | runtime | — | no | when set |
| 2 | `## Tool Call Behavior` | hardcoded const | — | **yes** | |
| 2.5 | (untitled) | **`AGENTS.md`** | **2000** | **yes** | non-empty |
| 3 | `## Available Tools` | granted tools, grouped | — | no | tools exist |
| 4 | Memory Protocol | recalled memories | — | no | always |
| 5 | Skills | skill summary + `SKILL.md` frontmatter context | 2000 | no | any skill |
| 6 | `## Connected Tool Servers (MCP)` | MCP summary | — | no | non-empty |
| 7 | `## Workspace` / `## Identity` / `## Persona` / `## User Context` / `## Long-Term Memory` | workspace path, **`IDENTITY.md`**, **`SOUL.md`**, **`USER.md`**, **`MEMORY.md`** | — / **500** / **1000** / **500** / **500** | **yes** | each non-empty |
| 7.5 | `## Heartbeat Checklist` | **`HEARTBEAT.md`** | **1000** | **yes** | **`is_autonomous` only** |
| 8 | User Personalization | `user_name` | — | **yes** | |
| 9 | Channel Awareness | channel type | — | **yes** | |
| 9.1 | `## Sender` | sender name/id | — | **yes** | |
| 9.5 | Peer Agent Awareness | other agents | — | **yes** | peers exist |
| 10 | Safety & Oversight | hardcoded const | — | **yes** | |
| 11 | Operational Guidelines | hardcoded const | — | no | always |
| 13 | `## First-Run Protocol` | **`BOOTSTRAP.md`** | **1500** | **yes** | **only if no `user_name` memory AND `user_name` is None** |
| 14 | Workspace Context | auto-detected | **1000** | **yes** | |
| 15 | `## Live Context` | **`context.md`** | **8000** | **no** | non-empty |

Section 12 (canonical/compacted context) was **moved out of the system prompt** into
`build_canonical_context_message()` "to keep the system prompt stable across turns for provider prompt
caching."

**`TOOLS.md` is not read by the prompt builder at all.** It is in `workspace_context.rs`'s `CONTEXT_FILES`
(alongside AGENTS/SOUL/IDENTITY/HEARTBEAT), which feeds Section 14 — and that builder takes only the **first
200 chars** of each file as a preview, then the whole section is capped at 1000. Its own header calls it
"(not synced)". **Writing anything substantive in `TOOLS.md` is wasted.**

Other hard facts from the same files:

- **`SOUL.md` has its ``` code blocks stripped** before capping (`strip_code_blocks`, `prompt_builder.rs:622-640`)
  — deliberately, so the model calls tools instead of echoing commands. **Command examples in `SOUL.md`
  silently vanish.**
- `cap_str` truncates on a char boundary and appends `"..."`.
- Context files over **32 KB** are skipped entirely: `MAX_FILE_SIZE: u64 = 32_768`
  (`workspace_context.rs:14`), log `Skipping oversized context file`.
- Workspace context files are **mtime-cached and re-read on change** (`workspace_context.rs:97-121`) —
  **editing `SOUL.md`/`AGENTS.md` does NOT require a daemon restart.** This is the opposite of `config.toml`
  and `custom_models.json`, which are cached at boot with no reload path.
- `BOOTSTRAP.md` fires **once, ever** — the heuristic is "no `user_name` memory exists". After the agent
  stores `user_name`, it is never injected again.
- Subagents get a stripped prompt: identity, date, tools, memory, skills, MCP, operational guidelines,
  and `context.md`. **No persona, no AGENTS.md, no safety section.**

### The real content of the bundled workspace files

They are near-empty scaffolds, not content. VERIFIED
(`wc -l ~/.openfang/workspaces/assistant/*.md`): AGENTS.md 20, BOOTSTRAP.md 11, HEARTBEAT.md 12,
IDENTITY.md 11, SOUL.md 4, MEMORY.md 2, TOOLS.md 2, USER.md 5.

```markdown
# SOUL.md (all 4 lines) — role: persona/tone. Cap 1000.
# Soul
You are assistant. General-purpose assistant agent. The default OpenClaw agent for everyday tasks, questions, and conversations.
Be genuinely helpful. Have opinions. Be resourceful before asking.
Treat user data with respect — you are a guest in their life.
```

```markdown
# IDENTITY.md — role: visual identity + personality. YAML frontmatter. Cap 500.
---
name: assistant
archetype: assistant
vibe: helpful
emoji:
avatar_url:
greeting_style: warm
color:
---
# Identity
<!-- Visual identity and personality at a glance. Edit these fields freely. -->
```

Frontmatter field domains (UPSTREAM `agent.rs`, `struct AgentIdentity`): `archetype` ∈ researcher, coder,
assistant, writer, devops, support, analyst · `vibe` ∈ professional, friendly, technical, creative, concise,
mentor · `greeting_style` ∈ warm, formal, playful, brief · `emoji` single char · `color` hex e.g. `#FF5C00` ·
`avatar_url` http(s) or data URI.

```markdown
# AGENTS.md (excerpt) — role: behavior contract. Cap 2000. The highest-leverage file after system_prompt.
# Agent Behavioral Guidelines
## Core Principles
- Act first, narrate second. Use tools to accomplish tasks rather than describing what you'd do.
- Batch tool calls when possible — don't output reasoning between each call.
- When a task is ambiguous, ask ONE clarifying question, not five.
## Tool Usage Protocols
- file_read BEFORE file_write — always understand what exists.
- shell_exec: explain destructive commands before running.
```

```markdown
# BOOTSTRAP.md (excerpt) — role: first-run ritual, fires ONCE. Cap 1500.
1. **Greet** — Introduce yourself as assistant with a one-line summary of your specialty.
2. **Discover** — Ask the user's name and one key preference relevant to your domain.
3. **Store** — Use memory_store to save: user_name, their preference, and today's date as first_interaction.
4. **Orient** — Briefly explain what you can help with (2-3 bullet points, not a wall of text).
5. **Serve** — If the user included a request in their first message, handle it immediately after steps 1-3.
```

`MEMORY.md` ("Long-Term Memory — curated knowledge the agent preserves across sessions") and `USER.md`
("Name: / Timezone: / Preferences:", "Updated by the agent as it learns about the user") ship as empty
templates. `HEARTBEAT.md` is an unchecked checklist ("Check for pending tasks or messages", "Review memory for
stale items"), injected **only** for `is_autonomous` agents.

### `context.md` — the undocumented live channel

UPSTREAM `crates/openfang-runtime/src/agent_context.rs`. **`CONTEXT_FILENAME = "context.md"`,
`MAX_CONTEXT_BYTES = 32_768`**, injected at `<workspace>/context.md`, capped at **8000 chars** in the prompt.

- **Re-read every turn** — an external writer (a cron job refreshing live data) shows up on the very next
  message, no restart. Upstream issue #843.
- **`cache_context = true` freezes the first read** — the upstream test is literally named
  `cache_context_true_freezes_first_read`. The key name suggests provider prompt caching. It is not.
- On a read error with a cache present: `Failed to re-read context.md; falling back to cached content`.
- **It is the only context file injected into subagents.**
- VERIFIED: **it does not exist in any of the 30 workspaces** (`ls ~/.openfang/workspaces/*/context.md` →
  `No such file or directory`). You create it. **This is the correct mechanism for feeding live/dynamic data
  to an agent** — far better than rewriting `SOUL.md`.

---

## Creating an agent end-to-end

### CLI surface — VERIFIED (`openfang agent --help`)

```
new    Spawn a new agent from a template (interactive or by name)
spawn  Spawn a new agent from a manifest file
list   List all running agents
chat   Interactive chat with an agent
kill   Kill an agent
set    Set an agent property (e.g., model)
```

```
openfang agent new [TEMPLATE]        # [TEMPLATE] e.g. "coder"; interactive picker if omitted
openfang agent spawn <MANIFEST>      # <MANIFEST> = path to an agent manifest TOML file
openfang agent set <AGENT_ID> <FIELD> <VALUE>   # <AGENT_ID> is a UUID; <FIELD> = model
```

**`agent set` accepts exactly one field: `model`.** VERIFIED — `openfang agent set --help` says
`<FIELD>  Field to set (model)`. There is no CLI path to change temperature, tools, or schedule. Edit the TOML.

**The upstream doc is wrong about the CLI.** `docs/agent-templates.md` Quick Start shows
`openfang spawn orchestrator` and `openfang spawn --template agents/writer/agent.toml`. VERIFIED:

```bash
openfang spawn --help
# error: unrecognized subcommand 'spawn'
```

There is no top-level `spawn`. It is `openfang agent new <template>` / `openfang agent spawn <manifest-path>`.

**`docs/agent-templates.md` is also stale on models.** It documents 4 tiers with concrete providers
(`orchestrator → deepseek/deepseek-chat`, `coder → gemini/gemini-2.5-flash`, `assistant → groq/llama-3.3-70b-versatile`).
**No shipped manifest matches.** VERIFIED — all 30 on-disk manifests are `provider = "default"` /
`model = "default"`; the tier providers survive only as the vestigial `api_key_env` values. **Trust the TOML,
not the doc.**

### Recommended flow (safe on this install)

```bash
# 1. Copy the closest bundled manifest as a base
cp -r ~/.openfang/agents/hello-world ~/.openfang/agents/my-agent
$EDITOR ~/.openfang/agents/my-agent/agent.toml     # set name = "my-agent" — MUST match the dir name

# 2. Spawn from the manifest path
openfang agent spawn ~/.openfang/agents/my-agent/agent.toml
```

Or drop the directory in and **restart** — auto-spawn picks it up (UPSTREAM `kernel.rs:1466-1474`, issue
#1140): *"auto-spawn agents from `~/.openfang/agents/<name>/agent.toml` that are present on disk but not yet in
the registry. Without this, user-placed agent dirs never appear in `GET /api/agents` (and thus the chat tab's
dropdown) until they are explicitly spawned via API or CLI."* The scan is idempotent.

On spawn, OpenFang creates `~/.openfang/workspaces/<name>/` and generates the identity `.md` files unless
`generate_identity_files = false`. The dashboard additionally `PUT`s `/api/agents/{id}/files/SOUL.md` when a
personality preset is chosen (VERIFIED in the bundled JS).

### Minimal correct manifest for this install

```toml
name = "my-agent"                    # must equal the directory name
version = "0.1.0"
description = "One line — shown in agent list."
author = "kyzdes"
module = "builtin:chat"
tags = ["custom"]

[model]
provider = "default"                 # BOTH must be "default" for the [default_model] overlay
model = "default"
max_tokens = 4096
temperature = 0.3
system_prompt = """You are My Agent. …"""   # UNCAPPED — put the real instructions here
# do NOT set api_key_env — let it inherit GONKA_1_API_KEY

[resources]
max_llm_tokens_per_hour = 100000     # the only budget that bites
max_tool_calls_per_minute = 60       # the REAL concurrency-ish knob (max_concurrent_tools is ignored)

[capabilities]
tools = ["file_read", "file_list", "memory_store", "memory_recall"]
network = ["*"]
memory_read = ["*"]
memory_write = ["self.*"]
agent_spawn = false

# NO [schedule] SECTION — deliberate. Reactive default = zero background LLM spend.
# If this agent must run on a timer AND deliver its output, do NOT add [schedule] here:
# it has no delivery. Create a cron job instead -> automation.md.
# Setting both = two independent timers = 2x the spend.
```

Get `temperature` and `max_tokens` right **on first write** — neither is in the boot `changed` diff, so
editing them later is silently ignored unless a diffed field (e.g. `description`) also changes. See
[TOML vs DB](#toml-on-disk-vs-db--what-actually-reloads).

### HTTP API — UNVERIFIED (daemon is down; POST is forbidden by policy here)

Per `docs/agent-templates.md`, which is demonstrably stale on the CLI — treat as unconfirmed:

```bash
curl -X POST http://localhost:4200/api/agents -H "Content-Type: application/json" -d '{"template":"coder"}'
curl -X POST http://localhost:4200/api/agents -H "Content-Type: application/json" -d '{"template":"writer","model":"gemini-2.5-flash"}'
curl -X POST http://localhost:4200/api/agents/{id}/message -H "Content-Type: application/json" -d '{"content":"…"}'
```

**Trailing-slash routes 404** (`/api/agents/` fails, `/api/agents` works) even though the slash forms are the
literals in the binary.

---

## TOML on disk vs DB — what actually reloads

On every boot, for each agent, the kernel diffs the on-disk manifest against the DB copy. UPSTREAM
`kernel.rs:1300-1345`. The upstream comment is a warning worth quoting:

> *"IMPORTANT: keep this list in sync with AgentManifest fields that users may legitimately edit in
> agent.toml. **Missing a field here means changes to it are silently ignored until the agent is deleted and
> recreated.**"*

**Fields in the `changed` diff** (edit any of these and the manifest reloads):
`name`, `description`, `model.system_prompt`, `model.provider`, `model.model`, `capabilities.tools`,
`tool_allowlist`, `tool_blocklist`, `skills`, `mcp_servers`, `workspace` (only when the TOML sets one),
`schedule`, `autonomous`, `resources`, `exec_policy`.

**Fields NOT in the diff** (edited alone → **silently ignored forever**):
`model.max_tokens`, `model.temperature`, `model.api_key_env`, `model.base_url`, **`fallback_models`**,
**`capabilities.network` / `.shell` / `.memory_read` / `.memory_write` / `.agent_spawn` / `.agent_message` /
`.ofp_*`**, `profile`, `tags`, `priority`, `routing`, `pinned_model`, `cache_context`, `max_history_messages`,
`metadata`, `generate_identity_files`, `version`, `author`, `module`.

**Read that list again: `capabilities.shell` — the shell allowlist — is not diffed.** Tightening it alone and
restarting changes nothing.

When `changed` is true the merge is **total** — `merge_disk_manifest_preserving_kernel_defaults(disk, entry)`
returns `disk` wholesale, preserving from the DB only `workspace` and `exec_policy` **when disk omits them**
(UPSTREAM `kernel.rs:6744-6755`). So:

> **Workaround: to make an undiffed edit (temperature, shell, fallbacks) take effect, also touch a diffed
> field in the same file — bump `version`… no: `version` is not diffed either. Touch `description`.** Then the
> whole disk manifest, including your undiffed edit, replaces the DB copy.

**On THIS install `changed` is true for all 30 agents on every boot anyway**, so undiffed edits *do* currently
land. VERIFIED:

```bash
openfang agent list 2>&1 | grep "TOML on disk" | head -5
# INFO openfang_kernel::kernel: Agent TOML on disk differs from DB, updating agent=data-scientist
# INFO openfang_kernel::kernel: Agent TOML on disk differs from DB, updating agent=legal-assistant
# INFO openfang_kernel::kernel: Agent TOML on disk differs from DB, updating agent=debugger
# … ×30
```

**Why it always fires:** disk says `model.provider = "default"` while the DB holds the post-overlay
`"gonka-1"` — a permanent mismatch in a diffed field. **This is load-bearing but accidental.**

> **The pinning side effect — this is not trivia, it is the price of the most commonly requested change.**
> The moment someone writes a **concrete** provider into a manifest, that agent's diff goes quiet and its
> undiffed fields (`temperature`, `max_tokens`, `capabilities.shell`, `[[fallback_models]]`, …) **freeze at
> their DB values, permanently**. Every later edit to them is silently ignored until the agent is deleted and
> recreated. And [pinning a model to one agent](#pin-a-model-to-one-agent) — the normal answer to "make agent
> Y use model X" — **forces** you to write a concrete provider, because of the `&&` rule. So the correct way
> to do the task is also what disarms that agent's reload. **Get every undiffed field right in the same edit
> that pins the provider.** Nothing warns you at the point of use; that is why it is repeated here and there.

**Corollary — `agent set <id> model <x>` is reverted on the next restart**, because disk wins. To change a
model durably, edit `[model]` in the TOML.

---

## Addressing — UUID vs name

**Inconsistent, and there is no fix — just know which is which.**

| Takes a **UUID** | Takes a **name** |
|---|---|
| `agent chat <UUID>` | `chat <name>` |
| `agent kill <UUID>` | `message <name>` |
| `agent set <UUID> model <v>` | `memory list/get/set/delete <name>` |
| `trigger create <AGENT_ID> …` | `sessions <name>` |
| **`cron create <UUID> …`** ← its `--help` lies, saying "Agent name or ID" | |
| `/api/agents/{id}/*` · the whole cron HTTP API | |

**Get UUIDs the free way — this works with the daemon down and costs 0 audit rows:**
```bash
sqlite3 -readonly ~/.openfang/data/openfang.db "SELECT id,name FROM agents LIMIT 40;"
```

⚠️ `openfang agent list` below is the **expensive** way — with the daemon down it boots an in-process
kernel (+9 irreversible audit rows, G12). Shown for its output shape only; prefer the sqlite3 line.

```bash
openfang agent list 2>/dev/null | head -12
#  ID                                     NAME                 STATE        CREATED
#  -------------------------------------------------------------------------------------
#  462071d6-73f9-4772-9d29-1093e761f6c8 security-auditor     Running      2026-07-13 16:15
#  06209f92-2f6d-45e4-9e96-709f91cfceda devops-lead          Running      2026-07-13 16:15
#  c08fae4f-6c67-4733-a6ea-3610bdeecde0 health-tracker       Running      2026-07-13 16:15
```

VERIFIED. **`2>/dev/null` matters** — with the daemon down, `agent list` boots a full in-process kernel and
emits ~40 lines of INFO to stderr before the table. It is read-only w.r.t. your intent but it *does* run the
TOML→DB sync above.

The sentinel system agent is `00000000-0000-0000-0000-000000000001`.

**The DB's `agents.state` is stale and double-encoded.** VERIFIED:

```bash
sqlite3 ~/.openfang/data/openfang.db "SELECT id,name,state FROM agents LIMIT 3;"
# 6b951f63-fd5f-44c5-a31a-f9e3daa147b4|data-scientist|"suspended"
```

Note the **literal quotes inside the value** — `WHERE state='suspended'` matches nothing; you need
`state='"suspended"'`. And it says `suspended` while `agent list` says `Running` for all 30. **Never read agent
state from the DB.** Use `agent list` or `/api/agents`.

`AgentState` (UPSTREAM `agent.rs:174-187`): `created`, `running`, `suspended`, `terminated`, `crashed`.
`AgentMode` (`agent.rs:190-222`): `observe` (no tools at all), `assist` (only `file_read`, `file_list`,
`memory_recall`, `web_fetch`, `web_search`, `agent_list`), `full` (default). Mode is set at runtime via
`/api/agents/{id}/mode`, **not** in the manifest.

---

## Audit trail for agents

`audit_entries` is a Merkle-chained table (`seq`, `prev_hash`, `hash`). VERIFIED schema columns:
`seq, timestamp, agent_id, action, detail, outcome, prev_hash, hash`. **The column is `detail`, singular —
`details` does not exist and will error.**

```bash
sqlite3 ~/.openfang/data/openfang.db "SELECT action,COUNT(*) FROM audit_entries GROUP BY action ORDER BY 2 DESC;"
# ConfigChange|479      <- GROWS. See below.
# AgentMessage|477      <- frozen: nothing has run since the daemon stopped
# AgentSpawn|30
```

**These counts are snapshots, not invariants — `ConfigChange` grows every time you run the wrong command.**
Each in-process kernel boot (`status`, `agent list`, `agent new`, `agent spawn`, `agent kill` **while the
daemon is down**) writes **+9 `ConfigChange`/`ok` rows**. VERIFIED: this file first recorded
`ConfigChange|380` / `ok|469`; live now `479` / `568` — **+99 = exactly 11 × 9**, with `AgentMessage` frozen at
477 because no agent has actually run in between. So a growing `ConfigChange` count means *the playbook's own
readers have been booting ephemeral kernels*, not that anything changed the config. `AgentMessage` and
`AgentSpawn` are the stable ones. Prefer
`curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4200/api/health` (`000` = down) for liveness; it
writes nothing.

`AgentSpawn` detail format is `name=<agent>, parent=<None|uuid>`:

```bash
sqlite3 ~/.openfang/data/openfang.db "SELECT detail,outcome FROM audit_entries WHERE action='AgentSpawn' LIMIT 2;"
# name=data-scientist, parent=None|ok
# name=legal-assistant, parent=None|ok
```

**Failures live in `outcome`, not `detail`.** That is the single most useful debugging fact here — grep
`outcome`:

```bash
sqlite3 ~/.openfang/data/openfang.db \
  "SELECT substr(outcome,1,70),COUNT(*) FROM audit_entries GROUP BY substr(outcome,1,70) ORDER BY 2 DESC LIMIT 5;"
```

Live top outcomes on this install (VERIFIED, re-checked): `ok` **568** (grows +9 per in-process kernel boot —
see above), NIM connection errors **237** (`error: LLM driver error: Request failed: HTTP …`), `Boot failed: …
Missing API key: Set GROQ_API_KEY` **138** (historical — stopped dead at 19:29 on 2026-07-13), `Provider
overloaded` **19**, and the NIM `DEGRADED function cannot be invoked` 400 **15**. Only `ok` moves while the
daemon is down; the error counts are frozen and are a record of the last live window.

`openfang.db` is **0644 — world-readable** and contains full transcripts, while `config.toml`/`secrets.env` are
0600. Flag this if the user asks about hardening.

---

## Trap summary

| Trap | Consequence | Tag |
|---|---|---|
| **`[schedule]` for "run every N min and post to X"** | **No delivery exists. Burns tokens, posts nothing, forever, silently. Use cron → `automation.md`.** | VERIFIED |
| `[schedule]` **and** a cron job together | Two independent timers → 2× runs, 2× spend, one delivers | UPSTREAM |
| `pinned_model` / `[routing]` | Not in the boot diff → set alone, silently ignored forever. Looks like the answer to "pin a model"; isn't. | VERIFIED |
| Pinning a concrete `provider` into a manifest | That agent's diff goes quiet **permanently** → its undiffed fields freeze at DB values | VERIFIED |
| Pinning one agent's model | Fallbacks 1+ still come from **global** `[[fallback_providers]]` → silently answers on the old model | VERIFIED |
| `models-providers.md` Recipe B for one agent | Switches the **global** default — moves all 30 agents incl. the Telegram bot | VERIFIED |
| `provider="default"` + concrete `model` | Overlay skipped → `Unknown provider 'default'` | UPSTREAM |
| No `[model]` section at all | Defaults to `anthropic`/`claude-sonnet-4` — **not** `[default_model]` | UPSTREAM |
| `max_concurrent_tools` | **Not a schema field. Silently dropped.** Use `max_tool_calls_per_minute`. | VERIFIED |
| Any unknown/typo'd key | Silently dropped — no `deny_unknown_fields` | UPSTREAM |
| `priority = "normal"` | Must be capitalized (`"Normal"`) — only enum without `rename_all` | UPSTREAM |
| Editing `temperature`/`shell`/`[[fallback_models]]` alone | Not in the boot diff → ignored (unless another diffed field also changed) | UPSTREAM |
| `agent set <id> model x` | Reverted next restart — disk wins | UPSTREAM |
| `capabilities.shell = ["git *"]` | Prefix match on the whole string — `git x; rm -rf ~` passes this layer | UPSTREAM |
| `capabilities.shell` without `exec_policy` | Grants nothing beyond 18 `safe_bins` (mode defaults to Allowlist, `allowed_commands = []`) | VERIFIED |
| `shell_env_passthrough = ["*"]` | Leaks every secret into subprocesses | UPSTREAM |
| `profile = "full"` | One word ⇒ `tools/network/shell = ["*"]` + `agent_spawn` | UPSTREAM |
| `profile` + non-empty `tools` | Profile's tool list silently ignored | UPSTREAM |
| Long `SOUL.md` | Capped at 1000 chars; code blocks stripped | UPSTREAM |
| Anything in `TOOLS.md` | Never read by the prompt builder | UPSTREAM |
| Context file > 32 KB | Skipped entirely, silently | UPSTREAM |
| `cache_context = true` | Freezes `context.md`; unrelated to prompt caching | UPSTREAM |
| `max_history_messages = 0` | Coerced to 20, not "unlimited" | UPSTREAM |
| `[[fallback_models]]` in 21 of 30 | `default`/`default` → falls back to the model that just failed | VERIFIED |
| `[[fallback_providers]]` vs `[[fallback_models]]` | Different keys, different files | VERIFIED |
| `openfang spawn <template>` | Does not exist — the doc lies. Use `agent new`. | VERIFIED |
| `docs/agent-templates.md` tiers | Stale — no manifest matches | VERIFIED |
| `sqlite3 … agents.state` | Stale **and** double-quoted (`'"suspended"'`) | VERIFIED |
| `audit_entries.details` | Column is `detail`; failures are in `outcome` | VERIFIED |
| `ops` `every 5m` + `orchestrator` 120 s | 1000+ autonomous LLM calls/day for "No actionable items" | VERIFIED |
| `agent list` with daemon down | Boots a full in-process kernel; runs the TOML→DB sync | VERIFIED |

## Open questions

- **SUSPECT** — the pre-19:29 `[default_model]` value. All backups already read `gonka-1`; no `ConfigChange`
  rows in the window. **Settled by:** `OPENFANG_HOME=/tmp/of-probe openfang init --quick` then reading the
  generated `[default_model]`.
- **UNVERIFIED** — `POST /api/agents` template spawn and `{"model": …}` override. Daemon down; POST forbidden
  under the read-only mandate. Source is `docs/agent-templates.md`, already proven stale on the CLI.
- **UNVERIFIED** — whether `[model] api_key_env = "GEMINI_API_KEY"` degrades `coder`/`researcher` on a *spawn*
  (where the manifest hint wins) versus a *restore* (where `[default_model]` overwrites it). No GEMINI rows
  exist because none of those 8 agents is scheduled. **Settled by:** `openfang agent chat <coder-uuid>` with
  the daemon up and watching for a 401 from gonkagate.
- **SUSPECT** — whether a **pinned** agent needs `base_url` in its own `[model]` block, or whether
  `[provider_urls]` resolves it. Two statements collide and neither is tested. **Settled by:** the boot-log
  grep in [Pin a model to ONE agent](#pin-a-model-to-one-agent). Until then, set `base_url` defensively.
- ✅ **SETTLED 2026-07-14** — the `api_key_env` assignment (`kernel.rs:1436-1439`) sits **INSIDE** the
  `is_default_provider && is_default_model` guard. Pinning to a **different-key-family** provider
  survives a restart intact. Proved by pinning `hello-world` to `nim-1` + `NIM_1_API_KEY`, restarting,
  and confirming via `usage_events` that the call actually reached NVIDIA NIM and authenticated. The
  old "pin within one key family until settled" advice is obsolete — see the main entry above.
- **UNVERIFIED** — `pinned_model`'s value format and its interaction with `[model] model`. It is live code
  (the strings are in the binary) but zero of the 30 agents use it and it is not in the boot diff.
- **UNVERIFIED** — whether kernel-side cron `delivery_targets` fan-out is subject to agent capability checks.
  See [`[capabilities]`](#capabilities--the-security-boundary).
