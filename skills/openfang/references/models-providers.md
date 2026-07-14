# Models & Providers (OpenFang v0.6.9)

**Read this when** the task touches: which model an agent uses, `[default_model]` /
`[[fallback_providers]]` / `[provider_urls]`, `custom_models.json`, adding a model or a custom
OpenAI-compatible provider, switching the default model, **pinning a model to one agent**,
`pinned_model` / `[routing]`, diagnosing `driver_index=N` fallback spam, `Model not found` /
`not found in catalog`, parallel-tool-call 500s, provider API-key env vars, or why cost/budget
numbers are all `0.0`.

**Pick the recipe first — they are not interchangeable:**

| Task | Recipe | Blast radius |
|---|---|---|
| Make model X *available* | [A](#recipe-a--add-a-model) | none |
| "Use X from now on" / "switch the model" | [B](#recipe-b--switch-the-default-model) | **all 30 agents** |
| "Use X for agent Y" | [C](#recipe-c--pin-a-model-to-a-single-agent) | one agent |

**Do not reach for `pinned_model` for Recipe C's task — it is inert on this install**
([why](#-first-pinned_model-is-not-the-answer-it-is-inert-on-this-install)).

Everything marked **VERIFIED** was observed on THIS install (`/home/kyzdes/.openfang`, v0.6.9,
2026-07-14). The daemon was **DOWN** during verification — claims needing a live daemon are marked
**UNVERIFIED**. Upstream is **abandoned** (last commit = v0.6.9); docs are stale.

---

## The four things that waste the most time (read first)

1. **`openfang models list` does NOT show your custom models — ever, in-process.** It prints the
   **205-model builtin catalog only**. Your `custom_models.json` entries are invisible to it.
   `openfang models list --provider gonka-1` returns an **empty table**, not an error. The daemon's
   boot log is the only source of truth for the merged catalog. **Never use `models list` to verify
   a model you just added.** (VERIFIED — see [The CLI lies](#the-cli-surface--and-where-it-lies))

2. **The model registry is cached in memory at boot. There is NO reload command.** Editing
   `custom_models.json` changes nothing until a full restart. Worse, the daemon may **rewrite the
   file on stop**, silently reverting your edit. The only safe sequence is
   **stop → write → start** ([safe edit sequence](#the-boot-cache-rule-and-the-safe-edit-sequence)).
   `[provider_urls]` is the exception — it hot-reloads.

3. **`custom_models.json` is keyed by `(id, provider)`, not by `id`.** One model reachable through
   four provider aliases needs **four separate entries**. Registering `moonshotai/kimi-k2.6` once
   and listing `gonka-2` in `[[fallback_providers]]` gives you a model that is
   **`'moonshotai/kimi-k2.6' not found in catalog`** on that provider. (VERIFIED)

4. **`custom_models.json`, `[[fallback_providers]]`, and `[provider_urls]` are undocumented
   upstream.** `docs/providers.md` documents `fallback_models = ["a","b"]` (array of strings) —
   **that form does not exist in 0.6.9**. The real key in `agent.toml` is `[[fallback_models]]`
   (array of tables); the real key in `config.toml` is `[[fallback_providers]]`. Do not trust
   upstream docs here; trust this file. (VERIFIED + UPSTREAM)

---

## This install's topology (VERIFIED)

`cat /home/kyzdes/.openfang/config.toml` (47 lines, mode 0600):

```toml
api_listen = "127.0.0.1:4200"

[default_model]
api_key_env = "GONKA_1_API_KEY"
base_url    = "https://api.gonkagate.com/v1"
model       = "moonshotai/kimi-k2.6"
provider    = "gonka-1"

[[fallback_providers]]                       # gonka-2, gonka-3, gonka-4 identical but for the key
api_key_env = "GONKA_2_API_KEY"
base_url    = "https://api.gonkagate.com/v1"
model       = "moonshotai/kimi-k2.6"
provider    = "gonka-2"

[[fallback_providers]]                       # LAST RESORT
api_key_env = "NIM_1_API_KEY"
base_url    = "https://integrate.api.nvidia.com/v1"
model       = "meta/llama-3.3-70b-instruct"
provider    = "nim-1"

[provider_urls]
gonka-1 = "https://api.gonkagate.com/v1"
gonka-2 = "https://api.gonkagate.com/v1"
gonka-3 = "https://api.gonkagate.com/v1"
gonka-4 = "https://api.gonkagate.com/v1"
nim-1   = "https://integrate.api.nvidia.com/v1"
```

Keys live in `/home/kyzdes/.openfang/secrets.env` (0600): `GONKA_1..4_API_KEY`, `NIM_1_API_KEY`,
`TELEGRAM_BOT_TOKEN`. **Not** in a `.env` — which is why `openfang doctor` wrongly reports
"No LLM provider API keys found!" while the daemon authenticates fine.

`gonka-1..4` and `nim-1` are **invented provider names**. They are not among the 42 builtin
providers. A custom provider is created purely by naming it in `[default_model]` /
`[[fallback_providers]]` — there is no registration step. Note `nim-1` deliberately shadows nothing:
the builtin `nvidia` provider already points at the same base URL, but reusing `nvidia` would
inherit its 5 builtin models and its `NVIDIA_API_KEY` derivation.

Boot proof (`/home/kyzdes/.openfang/daemon-start.log`):

```
INFO openfang_kernel::kernel: Fallback provider configured provider=gonka-2 model=moonshotai/kimi-k2.6
INFO openfang_kernel::kernel: Fallback provider configured provider=gonka-3 model=moonshotai/kimi-k2.6
INFO openfang_kernel::kernel: Fallback provider configured provider=gonka-4 model=moonshotai/kimi-k2.6
INFO openfang_kernel::kernel: Fallback provider configured provider=nim-1  model=meta/llama-3.3-70b-instruct
INFO openfang_kernel::kernel: applied 5 provider URL override(s)
INFO openfang_kernel::kernel: Model catalog: 334 models, 143 available from configured providers (6 local)
  ✔ Kernel booted (gonka-1/moonshotai/kimi-k2.6)
```

Note `[default_model]` does **not** emit a "Fallback provider configured" line — only the 4
fallbacks do. The `✔ Kernel booted (<provider>/<model>)` line is the default-model receipt.

### `base_url` vs `[provider_urls]` — set BOTH

This install sets the URL in **both** places for every provider. They are different mechanisms:

| | `base_url` inside `[default_model]`/`[[fallback_providers]]` | `[provider_urls]` table |
|---|---|---|
| Scope | that one driver entry | provider name, globally (incl. agents that name the provider) |
| Boot log | (none) | `applied 5 provider URL override(s)` |
| Hot-reload | **No** — restart required | **Yes** — `Hot-reload: applying provider URL overrides` (string in binary) |

**Set both.** `[provider_urls]` is what makes the provider name resolvable anywhere else
(agent.toml `[model] provider = "gonka-1"`); `base_url` is what the chain driver itself uses.
Omitting `[provider_urls]` for a custom provider name leaves it with no known URL outside the chain.
(VERIFIED that both are present and boot applies 5 overrides; the failure mode of omitting one is
**UNVERIFIED** — would need a daemon restart with one removed.)

#### A pinned agent does NOT need its own `base_url` (settled — UPSTREAM)

`Kernel::resolve_driver` (`crates/openfang-kernel/src/kernel.rs:5562`, fetched from upstream `main`
= v0.6.9) resolves the primary driver's URL in exactly this order:

```rust
let base_url = if has_custom_url {                       // manifest [model] base_url
    manifest.model.base_url.clone()
} else if agent_provider == default_provider {           // agent pinned to gonka-1 == default
    effective_default.base_url.clone()
        .or_else(|| self.lookup_provider_url(agent_provider))
} else {                                                 // agent pinned to nim-1 etc.
    self.lookup_provider_url(agent_provider)             // ← reads [provider_urls] + catalog
};
```

So **`[provider_urls]` alone is sufficient for an agent-level pin, on both branches.** Writing
`base_url` into an `agent.toml` `[model]` block is **redundant** when the provider already appears in
`[provider_urls]` — which, on this install, all five do. It is not harmful, but it is a second place
to forget to update. **Prefer `[provider_urls]`; leave `base_url` out of agent manifests.**

The same function answers the API-key half. `api_key_env` in the manifest is only a *hint*: if absent
and the agent's provider **is** the default provider, `[default_model].api_key_env` is used; if absent
and the provider **differs**, the name is computed by `resolve_api_key_env` (below). **Do not set
`api_key_env` in a pinned agent manifest** — convention already resolves `gonka-1 → GONKA_1_API_KEY`
and `nim-1 → NIM_1_API_KEY`, both of which exist in `secrets.env`.

---

## Every configured provider is dead at once

**This is not hypothetical — it is the state this install was in when it went down** (178
`Fallback driver failed`, every index 0→5 exhausted, continuously for the 41 minutes of the last
session). Recipes A/B/C all presuppose you already know a provider that *works*. This is the
procedure for when none does. **Run it BEFORE restarting** — a restart into a dead chain gives you a
bot that connects to Telegram and never answers, while `ops` (every 5m, 288 runs/day) hammers it.

**1. Confirm it is the chain, not the channel** (free, daemon down):
```bash
sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log | grep -c 'Fallback driver failed'
```

**2. Probe the providers directly.** ⚠️ **The playbook had no gonka probe at all until 2026-07-14** —
`gotchas.md` G15 supplied one for NIM, the *last* and least important link, while **gonka — the
primary, and 4 of the 5 chain entries — had none.** This is the probe that decides whether a restart
is worth anything:
**⚠️ Do NOT probe `/v1/models`. It answers the wrong question — differently, for each provider.**
VERIFIED 2026-07-14, all four cells executed:

| Probe | Result | Verdict |
|---|---|---|
| `gonka /v1/models` + real key | `200` | |
| `gonka /v1/models` **no key** | `401` | discriminates auth ✔ |
| `nim /v1/models` + real key | `200` | |
| `nim /v1/models` + **garbage key** (`nvapi-INVALID`) | **`200`** | **useless — the endpoint is public** |

A NIM `/v1/models` `200` tells you the host resolves. It tells you **nothing** about your key, your
quota, or whether inference works. Use `/v1/chat/completions` with a 5-token request — it is the only
probe that exercises the same path the daemon uses:

```bash
set -a; . ~/.openfang/secrets.env; set +a          # 0600; never echo these

# gonka — the primary, and 4 of the 5 chain entries
curl -sS --max-time 45 -o /dev/null -w "gonka %{http_code} (%{time_total}s)\n" \
  -H "Authorization: Bearer $GONKA_1_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"moonshotai/kimi-k2.6","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
  https://api.gonkagate.com/v1/chat/completions

# nim — the last-resort fallback. NOTE the timeout: NIM needs ~10 s, gonka ~1 s.
curl -sS --max-time 60 -o /dev/null -w "nim   %{http_code} (%{time_total}s)\n" \
  -H "Authorization: Bearer $NIM_1_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"meta/llama-3.3-70b-instruct","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
  https://integrate.api.nvidia.com/v1/chat/completions
```

**VERIFIED — measured on this box:**

| Call | Code | Time | Note |
|---|---|---|---|
| gonka-1/2/3 chat, real key | `200` | **~1.2 s** | all three keys work |
| nim chat, real key | `200` | **~10.4 s** | ⚠️ **a `--max-time 20` reports a false `000` — it is just slow** |
| nim chat, garbage key | `403` | — | `{"status":403,"title":"Forbidden","detail":"Authorization failed"}` — this is how a bad NIM key actually looks |
| gonka chat, real key (one attempt) | **`000`** | 5 s | `Recv failure: Connection reset by peer` — **transient**; the same call succeeded 200/1.2 s moments later while `/v1/models` said `200` throughout |

**Two lessons, both counter-intuitive:**
1. **A short timeout manufactures an outage.** NIM at ~10 s exceeds any 5–8 s probe. Use ≥ 45 s.
2. **gonka can connection-reset on `chat/completions` while `/v1/models` returns `200`.** Host-up and
   inference-up are independent. Probe the path you actually use, and **retry once** before concluding
   anything — a single `000` here means nothing.

**3. Read the result:**

| gonka | nim | What it means | Do |
|---|---|---|---|
| `200` | any | It recovered; the 502s were an upstream outage | Just restart. Nothing to repoint. |
| `5xx`/timeout | `200` | gonka still down. **But a NIM `200` does NOT mean NIM works** — `DEGRADED function cannot be invoked` is a per-function 400 from a host that answers fine (G15). Do not let the green probe reassure you. | Recipes A+B, below |
| `5xx` | `5xx` | Nothing to repoint *to* from here | **Wait.** Do not thrash the config. Tell the user it is upstream. |

**4. If you must repoint (Recipe A + Recipe B):** while the daemon is stopped, change
`[default_model].model` **and all three gonka `[[fallback_providers]]`** — **all of them or none.**
Repoint the default alone and the first 502 silently downgrades everyone straight back to the dead
chain. Your offline inventory of what is even available is `custom_models.json` (129 entries) — there
is no other catalog with the daemon down.

**Do this while the daemon is already stopped.** You are inside the stop → edit → start rule anyway,
so fixing the chain now costs **zero** extra restarts. `daemon-lifecycle.md`'s pre-flight cannot help
you here: `doctor` is **blind to custom providers and `secrets.env`** (G20), so it structurally
cannot see a 502ing gonka.

---

## The fallback driver chain

Order = **agent `[model]` (index 0) → agent `[[fallback_models]]` → config `[[fallback_providers]]`
in file order**. The config `[default_model]` is what `provider = "default"` resolves to.

Failures log one line per driver, then classify:

```
WARN openfang_runtime::drivers::fallback: Fallback driver failed, trying next driver_index=0 model= error=API error (502): {...}
WARN openfang_runtime::drivers::fallback: Fallback driver failed, trying next driver_index=1 model=moonshotai/kimi-k2.6 error=API error (502): {...}
WARN openfang_runtime::drivers::fallback: Fallback driver failed, trying next driver_index=2 model=moonshotai/kimi-k2.6 ...
WARN openfang_runtime::drivers::fallback: Fallback driver failed, trying next driver_index=3 model=moonshotai/kimi-k2.6 ...
WARN openfang_runtime::drivers::fallback: Fallback driver failed, trying next driver_index=4 model=moonshotai/kimi-k2.6 ...
WARN openfang_runtime::drivers::fallback: Fallback driver failed, trying next driver_index=5 model=meta/llama-3.3-70b-instruct error=API error (503): {"error":{"message":"ResourceExhausted: Worker local total request limit reached (24/16)","type":"Service Unavailable","code":503}}
WARN openfang_runtime::agent_loop: LLM error classified: Provider overloaded: {...} category=Overloaded retryable=true raw=API error (503): {...}
WARN openfang_kernel::kernel: Agent loop failed — recorded in supervisor agent_id=91c689c2-... error=LLM driver error: Provider overloaded: {...}
WARN openfang_kernel::kernel: Background tick failed agent_id=91c689c2-... error=LLM driver error: ...
```

**What exhaustion looks like:** there is **no** "all drivers failed" message. Exhaustion is implicit
— the last `driver_index=N` WARN is immediately followed by `LLM error classified:` and
`Agent loop failed — recorded in supervisor`. The error surfaced to the user is the **last**
driver's error, not the first. So a gonka outage is reported to the user as an **NVIDIA NIM**
error. **Always read the whole `driver_index=` run, not the final line.**
(VERIFIED. `No drivers configured in fallback chain` is a distinct string in the binary — the
empty-chain case.)

### Trap: `driver_index=0` always logs `model=` (empty)

VERIFIED: 33/33 occurrences of `driver_index=0` in the boot log carry an **empty** `model=` field,
while indices 1..5 name a real model:

```
$ sed -E 's/\x1b\[[0-9;]*m//g' /home/kyzdes/.openfang/daemon-start.log \
  | grep -oE 'driver_index=[0-9]+ model=[^ ]*' | sort | uniq -c | sort -k2
     33 driver_index=0 model=
     33 driver_index=1 model=moonshotai/kimi-k2.6
     33 driver_index=2 model=moonshotai/kimi-k2.6
     33 driver_index=3 model=moonshotai/kimi-k2.6
      7 driver_index=4 model=meta/llama-3.3-70b-instruct
     26 driver_index=4 model=moonshotai/kimi-k2.6
     13 driver_index=5 model=meta/llama-3.3-70b-instruct
```

Index 0 is the agent's own `[model]` block. **SETTLED — it is only a label; nothing is wrong.**
`resolve_driver` builds the chain as (UPSTREAM `kernel.rs:5691-5693`, verbatim comment):

```rust
// Primary driver uses an empty model name so the request's `model` field
// (which is the agent's own model) is used as-is.
let mut chain = vec![(primary.clone(), String::new())];
```

The empty string is the chain entry's *model-name override slot*, deliberately blanked so the
request's own `model` field passes through. The real model **is** sent on the wire. Corroborated
here: index 0 returns the same gonka `502` as indices 1–4, i.e. gonka accepted and processed the
request. **Index 0 logs `model=` empty even when the agent is pinned to an explicit id** — so you
cannot use this line to confirm a pin took. Use `✔ Kernel booted` / the `Agent TOML on disk differs`
line instead.

### Trap: chain length varies per agent — `provider = "default"` duplicates a driver

Both a 5-driver chain (`index 0..4`) and a 6-driver chain (`index 0..5`) appear **within the same
boot, seconds apart** (08:15:16 vs 08:15:19) — so this is per-agent, not per-config.

VERIFIED cause: the extra driver comes from an agent-level `[[fallback_models]]` that resolves to
the **same** provider as the default. `/home/kyzdes/.openfang/agents/orchestrator/agent.toml`:

```toml
[model]
provider    = "default"
model       = "default"
api_key_env = "DEEPSEEK_API_KEY"     # ignored — provider="default" wins

[[fallback_models]]
provider    = "default"              # ← resolves to gonka-1 AGAIN
model       = "default"
api_key_env = "GROQ_API_KEY"         # ignored — provider="default" wins
```

So `orchestrator` gets: `0`=agent `[model]`→gonka-1, `1`=agent `[[fallback_models]]`→**gonka-1
again**, `2..4`=gonka-2/3/4, `5`=nim-1. An agent without `[[fallback_models]]` gets the plain
5-driver chain. VERIFIED that `orchestrator` (`91c689c2-17e3-4763-b360-65aea020cc57`) is the **only**
agent reaching `driver_index=5`.

**Consequence:** a `[[fallback_models]]` with `provider = "default"` is a **pure waste** — it retries
the identical provider that just failed, adding a full round-trip of latency to every failure.

Note the bogus `api_key_env` values (`DEEPSEEK_API_KEY`, `GROQ_API_KEY`) are **inert at runtime**
when `provider = "default"` — the resolved default provider's key is used. They are **not** inert at
boot validation, which is where the 138 audit rows `Boot failed: Missing API key: Set GROQ_API_KEY`
come from. Two code paths, no cross-awareness.

At least 10 bundled agents ship `[[fallback_models]]`:
```bash
grep -rl 'fallback_models' /home/kyzdes/.openfang/agents --include="agent.toml" | head -10
# debugger data-scientist legal-assistant meeting-assistant recruiter
# analyst social-media sales-assistant architect security-auditor  (+ orchestrator)
```

---

## `custom_models.json` — the whole schema

Path: `/home/kyzdes/.openfang/custom_models.json` (mode 0644, 49 081 B, **129 entries** here).
Top level is a **JSON array**, not an object. Filename confirmed as a literal in the binary.

Every entry, all fields (VERIFIED by exhaustive field census over all 129 entries):

```json
{
  "id": "moonshotai/kimi-k2.6",
  "display_name": "moonshotai/kimi-k2.6",
  "provider": "gonka-1",
  "tier": "custom",
  "context_window": 200000,
  "max_output_tokens": 32768,
  "input_cost_per_m": 0.0,
  "output_cost_per_m": 0.0,
  "supports_tools": true,
  "supports_vision": false,
  "supports_streaming": true,
  "aliases": []
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | **yes** (129/129) | Exact string sent to the provider. Slashes allowed — see [#1195](#1195--slashed-model-ids-when-it-actually-bites). |
| `display_name` | string | **yes** (129/129) | Free text. Every entry here just repeats `id`. |
| `provider` | string | **yes** (129/129) | Must match a provider name used in config. **Part of the key.** |
| `tier` | string | **yes** (129/129) | All 129 = `"custom"`. Bare lowercase `custom` and `local` exist in the binary; the builtin catalog renders `Frontier`/`Smart`/`Balanced`/`Fast`. Cosmetic — affects display/pickers only. |
| `context_window` | int | **yes** (129/129) | Used for context-overflow trimming. Lying here causes real truncation bugs. |
| `max_output_tokens` | int | **yes** (129/129) | |
| `input_cost_per_m` | float | **yes** (129/129) | USD per 1M input tokens. **`0.0` here → all cost tracking is dead.** |
| `output_cost_per_m` | float | **yes** (129/129) | |
| `supports_tools` | bool | **yes** (129/129) | `false` ⇒ the model is not offered tools. Set `false` on embedding models. |
| `supports_vision` | bool | **yes** (129/129) | 13 entries `true` here. |
| `supports_streaming` | bool | **yes** (129/129) | All 129 = `true`. |
| `aliases` | array\<string\> | **yes** (129/129) | All empty here. Shorthand names for `models set` / `[model] model`. |
| `model_type` | string | **optional** (11/129) | Only observed value: `"embedding"`. **Omit for chat models** — no `"chat"` value is used anywhere. Present on all 11 embedding entries. |

The 11 `model_type: "embedding"` entries (all `supports_tools:false`, correct real `context_window`):
`baai/bge-m3`(8192) · `nvidia/embed-qa-4`(512) · `nvidia/llama-3.2-nemoretriever-1b-vlm-embed-v1`(8192,
vision) · `nvidia/llama-3.2-nv-embedqa-1b-v1`(8192) · `nvidia/llama-nemotron-embed-1b-v2`(8192) ·
`nvidia/llama-nemotron-embed-vl-1b-v2`(8192, vision) · `nvidia/nv-embed-v1`(32768) ·
`nvidia/nv-embedcode-7b-v1`(32768) · `nvidia/nv-embedqa-e5-v5`(512) ·
`nvidia/nv-embedqa-mistral-7b-v2`(512) · `snowflake/arctic-embed-l`(512).

### How it merges with the builtin catalog: **additive, keyed by (id, provider)**

```
builtin catalog     205 models   (openfang models list | tail -n +3 | grep -c .)
custom_models.json  129 entries  (len(json.load(...)))
                    ---
boot log            334 models   ("Model catalog: 334 models, 143 available ... (6 local)")
```

**205 + 129 = 334 exactly.** VERIFIED. So the merge is a plain **append with no dedupe and no
override**. Consequences:

- **You cannot override a builtin model's metadata** by re-declaring the same `(id, provider)` —
  you get a duplicate row, not a replacement. (Inferred from the exact-sum arithmetic; **SUSPECT** —
  to settle, add a duplicate `(gpt-4o, openai)` entry, restart, and check whether the count goes
  206→335 or stays 334.)
- Custom providers are the safe pattern precisely *because* the name (`gonka-1`, `nim-1`) can't
  collide with a builtin one.
- **Orphan entries are silently accepted.** The previous file had **130** entries; exactly one,
  `("meta/llama-3.3-70b-instruct", "nvidia")`, referenced provider `nvidia` while config uses
  `nim-1` — dead weight that inflated the catalog with an unreachable model and never errored:
  ```bash
  # current(129) vs .bak-20260713(130) — the single removed key:
  only in bak: [('meta/llama-3.3-70b-instruct', 'nvidia')]
  ```

Provider distribution here (VERIFIED):

| provider | entries |
|---|---|
| `nim-1` | 121 |
| `gonka-1` / `gonka-2` / `gonka-3` / `gonka-4` | 2 each (= 8) |

Those 2 per gonka alias are `minimaxai/minimax-m2.7` and `moonshotai/kimi-k2.6` — **the 4× repetition
is mandatory**, one per provider alias in the chain.

**`143 available (6 local)`** — "available" = models whose provider has a resolvable API key.
121 nim-1 + 8 gonka + 6 local ollama + 8 others ≈ 143. The other ~191 builtin models are `Missing`
auth and can never be selected.

---

## The boot-cache rule and the safe edit sequence

**VERIFIED / seed:** the model registry is read once at boot into memory. **No reload command
exists** — not `models`, not `config`, not the API. `config_reload` hot-reloads memory/network/vault/
`api_listen`/approval-policy/provider-URL-overrides; `provider_api_keys` are documented as "takes
effect on next driver init". **`custom_models.json` is in none of those paths.**

**The daemon may rewrite `custom_models.json` on stop.** Writing while it runs = your edit is
overwritten by the in-memory snapshot at shutdown.

```bash
# THE ONLY SAFE SEQUENCE
openfang stop                                            # 1. MUST be fully down first
cp ~/.openfang/custom_models.json ~/.openfang/custom_models.json.bak-$(date +%Y%m%d-%H%M)
python3 - <<'EOF'                                        # 2. edit (validate JSON as you go)
import json, pathlib
p = pathlib.Path.home()/".openfang/custom_models.json"
d = json.loads(p.read_text())
d.append({
  "id": "zai-org/GLM-5.1", "display_name": "zai-org/GLM-5.1",
  "provider": "gonka-1", "tier": "custom",
  "context_window": 200000, "max_output_tokens": 32768,
  "input_cost_per_m": 0.0, "output_cost_per_m": 0.0,
  "supports_tools": True, "supports_vision": False, "supports_streaming": True,
  "aliases": [],
})
p.write_text(json.dumps(d, indent=2))
EOF
python3 -c "import json;print(len(json.load(open('$HOME/.openfang/custom_models.json'))))"   # 3. sanity
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start                            # 4. NEVER pipe to head
sleep 20 && grep -E 'Model catalog|not found in catalog' ~/.openfang/daemon-start.log | tail -5
```

**`openfang start` runs in the FOREGROUND. Piping it to `head` sends SIGPIPE and kills the
daemon.** (VERIFIED)

**Do NOT use `nohup … & disown` to detach it.** `disown` does not move the process out of the
systemd cgroup, so when `systemd-oomd` kills the terminal scope the daemon dies with it — VERIFIED
the hard way on this machine (`app-gnome-Alacritty-4436.scope: Failed with result 'oom-kill'`).
Use `systemd-run --user --unit=openfang`, as in the sequence above, or a `systemd --user` unit.
Full detail: `daemon-lifecycle.md`.

⚠️ **Verification caveat:** under a transient `systemd-run --user --unit=…` service the redirect above still captures the
daemon's output, but if you launch it via a systemd *unit* instead, output goes to the journal and
**`~/.openfang/daemon-start.log` will not exist** — the `grep`-the-log checks in this playbook then
silently find nothing. In that case read `journalctl --user -u <unit> | tail -50` instead. Absence
of the log is not evidence that the daemon failed.

**Verification is the boot log, never `models list`:** expect `Model catalog: 335 models, 144
available ...` (each count +1). If the count didn't move, your file wasn't reloaded or wasn't parsed.

**Config parse failure degrades to DEFAULTS silently** (`Failed to parse config, using defaults`) —
a broken `config.toml` does not stop the daemon, it quietly drops gonka entirely. Always grep the
boot log for `✔ Kernel booted (gonka-1/...)` after any config edit.

---

## The CLI surface — and where it lies

```
openfang models list [--provider P] [--json]   # builtin catalog ONLY (in-process)
openfang models aliases                        # 89 alias→model rows
openfang models providers                      # 42 builtin providers + auth status
openfang models set [MODEL]                    # MUTATES config.toml. Interactive picker if MODEL omitted.
```

**There is no `openfang models add`. Those four are the whole surface — adding a model means hand-editing
`custom_models.json` ([Recipe A](#recipe-a--add-a-model)), and there is no CLI or API shortcut.**
(VERIFIED: the binary's clap help table carries `Set the default model for the daemon` and the
`list`/`aliases`/`providers` rows, with **no** "add"-shaped model subcommand help string:
`strings -n 4 ~/.openfang/bin/openfang | grep -E '^Add a (custom )?model'` → no output.)

### `models list` — omits every custom model (VERIFIED)

```bash
$ openfang models list --provider gonka-1
MODEL                                    PROVIDER         TIER     CONTEXT
--------------------------------------------------------------------------------
                       # ← empty. Not an error. Same for --provider nim-1.

$ openfang models list | grep -i kimi
kimi-k2                                  moonshot         Frontier 131072
kimi-k2.5                                moonshot         Frontier 131072
kimi-for-coding                          kimi_coding      Frontier 262144
                       # ← kimi-k2.6 (our actual default model) is ABSENT
```

`--json` exposes only **4 fields** — no cost, tools, vision, or aliases:
```json
[ { "context_window": 200000, "id": "claude-opus-4-6", "provider": "anthropic", "tier": "Frontier" }, ... ]
```

### `models aliases` — renders **correctly** here, contradicting the seed

**SUSPECT.** The seed records `models aliases` as "broken (renders JSON envelope keys as rows)".
With the daemon **DOWN**, it is perfectly fine:

```bash
$ openfang models aliases | head -6
ALIAS                          RESOLVES TO
------------------------------------------------------------
copilot-4o                     gpt-4o
gpt4o                          gpt-4o
minimax-m2.5                   MiniMax-M2.5
gemini-pro                     gemini-3.1-pro-preview
# 89 rows total
```

Working theory: **daemon UP → CLI proxies to `/api/models/aliases` and mis-renders the JSON
envelope; daemon DOWN → in-process path renders correctly.** This also explains the `models list`
205-vs-334 split (in-process = builtin only; the API would serve the merged 334).
**To settle:** start the daemon, re-run both `models aliases` and `models list | wc -l`. If the
count jumps to 334 and aliases breaks, the theory holds and **the merged catalog is only visible via
the daemon** (`curl -s 127.0.0.1:4200/api/models`).

Until settled: **treat `models list`/`aliases` output as daemon-state-dependent and verify the
catalog from the boot log or `GET /api/models`, never from the CLI table.**

### `models providers` — 42 builtin providers, and **your custom ones are not there**

```bash
$ openfang models providers | grep -iE 'gonka|nim'
# (no output — gonka-1..4 and nim-1 do NOT appear)
```

This is **expected, not a bug**: the table enumerates the compiled-in provider registry. A custom
provider exists only in `config.toml` + `custom_models.json`. **Do not "fix" a missing gonka row.**

```
PROVIDER             AUTH         MODELS     BASE URL
anthropic            Missing      7          https://api.anthropic.com
openai               Missing      16         https://api.openai.com/v1
gemini               Missing      10         https://generativelanguage.googleapis.com
ollama               NotRequired  6          http://localhost:11434/v1
vllm                 NotRequired  1          http://localhost:8000/v1
lmstudio             NotRequired  1          http://localhost:1234/v1
nvidia               Missing      5          https://integrate.api.nvidia.com/v1
...  (42 rows; AUTH ∈ Missing | NotRequired)
```

Full 42: `anthropic openai gemini deepseek groq openrouter requesty mistral together fireworks
ollama vllm lmstudio lemonade perplexity cohere ai21 cerebras sambanova huggingface xai replicate
github-copilot chutes venice nvidia qwen minimax zhipu zhipu_coding zai zai_coding moonshot
kimi_coding qianfan volcengine volcengine_coding bedrock azure codex claude-code qwen-code`.
`AUTH=NotRequired`: `ollama vllm lmstudio lemonade claude-code qwen-code`.

### `models set` — a config mutation, not a runtime switch

`Set the default model for the daemon` / `[MODEL]  Model ID or alias (e.g. "gpt-4o",
"claude-sonnet"). Interactive picker if omitted`.

**Two traps:** (a) its picker is fed by the **builtin-only** catalog, so your custom models likely
aren't offered — **UNVERIFIED**, running it would mutate config; (b) like `config set`, it **strips
all TOML comments**. For a custom model, **edit `config.toml` by hand** ([recipe](#recipe-b--switch-the-default-model)).

---

## Drivers

Nine driver modules are compiled in (VERIFIED via
`strings -n 8 openfang | grep -oE 'crates/openfang-runtime/src/drivers/[a-z_]+\.rs' | sort -u`):

```
anthropic.rs  bedrock.rs  claude_code.rs  copilot.rs  fallback.rs
gemini.rs     openai.rs   qwen_code.rs    vertex.rs
```

`fallback.rs` is the chain orchestrator, not a provider. **There is no `ollama.rs`** — Ollama,
vLLM, LM Studio, and every OpenAI-compatible endpoint (including `gonka-*` and `nim-1`) go through
**`openai.rs`**.

UPSTREAM `docs/providers.md` states: *"three native drivers — Anthropic, Gemini, and an
OpenAI-compatible driver covering all other 18 providers."* The **18 is stale** — the live binary
ships 42 providers, so the OpenAI-compatible driver covers roughly 42 − {anthropic, gemini, bedrock,
github-copilot, claude-code, qwen-code, azure, codex} ≈ **34**. Treat "3 native drivers" as the
right *shape* and the count as wrong.

**Operationally: if your provider is OpenAI-compatible, you are on `openai.rs`, and every
`openai.rs` bug below applies to you.**

---

## Provider API-key env vars

Two mechanisms:

1. **Explicit** — `api_key_env = "GONKA_1_API_KEY"` in the config block. **Always do this for custom
   providers.** (VERIFIED — this install.)
2. **Derived** — **SETTLED (UPSTREAM).** `KernelConfig::resolve_api_key_env`
   (`crates/openfang-types/src/config.rs:1559`) is a three-step resolution:

   ```rust
   pub fn resolve_api_key_env(&self, provider: &str) -> String {
       // 1. Explicit mapping in [provider_api_keys]
       if let Some(env_var) = self.provider_api_keys.get(provider) { return env_var.clone(); }
       // 2. Auth profiles (first profile by priority)
       if let Some(profiles) = self.auth_profiles.get(provider) { /* lowest .priority wins */ }
       // 3. Convention: NVIDIA → NVIDIA_API_KEY
       format!("{}_API_KEY", provider.to_uppercase().replace('-', "_"))
   }
   ```

   The conventional transform is exactly `to_uppercase()` + `-`→`_` + `_API_KEY`, confirming
   `gonka-1 → GONKA_1_API_KEY` and `nim-1 → NIM_1_API_KEY`. **This install has neither
   `[provider_api_keys]` nor `[auth_profiles]`, so step 3 is what a keyless agent pin will hit — and
   it lands on the right var.** This is why an agent pinned to a custom provider needs **no**
   `api_key_env`.

Literal `*_API_KEY` strings present in the binary (`strings -n 6 openfang | grep -oE
'\b[A-Z][A-Z0-9]*_API_KEY\b' | sort -u`) — note most are **tools/channels, not LLM providers**:

```
ANTHROPIC_API_KEY  COHERE_API_KEY  DEEPSEEK_API_KEY  FIREWORKS_API_KEY  GEMINI_API_KEY
GOOGLE_API_KEY     GROQ_API_KEY    KIMI_API_KEY      MISTRAL_API_KEY    OPENAI_API_KEY
TOGETHER_API_KEY
— non-LLM: ALPACA_ BRAVE_ DEEPGRAM_ DISCOURSE_ ELASTICSEARCH_ ELEVENLABS_ EXA_ LINEAR_
           TODOIST_ ZULIP_ OPENFANG_ (+ placeholders APIOPENAI_API_KEY, MY_API_KEY)
```

Gemini accepts `GEMINI_API_KEY` **or** `GOOGLE_API_KEY` (UPSTREAM `docs/providers.md`).

**Where keys must live on THIS install: `~/.openfang/secrets.env` (0600).** `openfang doctor` looks
for `.env` and reports `` `.env` file not found `` / `No LLM provider API keys found!` — **that is a
false alarm; ignore it.** Two secret paths, no cross-awareness. (VERIFIED, seed)

---

## The parallel-tool-call incompatibility

**Verbatim error (greppable):**

```
API error (500): {"error":{"message":"Failed to generate completions: Failed to apply prompt
template: invalid operation: This model only supports single tool-calls at once! (in default:95)"}}
```

`(in default:95)` is a **Jinja chat-template** error at line 95 — it is raised by the *serving stack*
(vLLM/NIM-style template rendering), **not** by OpenFang and **not** by the model weights. It fires
when OpenFang emits >1 tool call in a single assistant turn.

**Affected models (VERIFIED):**

| Model | Provider | Parallel tool calls |
|---|---|---|
| `minimaxai/minimax-m2.7` | gonka | **FAILS** (500) — root-caused the Telegram silence (seed) |
| `meta/llama-3.3-70b-instruct` | nim-1 | **FAILS** (500) — same verbatim error, `driver_index=4` @ 08:11:17 |
| `moonshotai/kimi-k2.6` | gonka | **works** — 20 usage_events, no such error |

**Extension beyond the seed:** this is **not minimax-specific**. In this boot log the *only* model
observed emitting it is **NIM's `meta/llama-3.3-70b-instruct`** — i.e. **the last-resort fallback
shares the defect.** So even with the default fixed to kimi, any fall-through to `nim-1` on a
parallel-tool-call turn dies at the end of the chain.

```bash
sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log | grep 'single tool-calls' \
  | grep -oE 'driver_index=[0-9]+ model=[^ ]*' | sort | uniq -c
#       1 driver_index=4 model=meta/llama-3.3-70b-instruct
```

### There is no knob. The only fix is changing the model.

```bash
strings -n 8 /home/kyzdes/.openfang/bin/openfang | grep -icE 'parallel_tool_calls'
# 0
```

**VERIFIED: zero occurrences of `parallel_tool_calls` in the 66 MB binary.** It is not a config key,
not an agent.toml key, not an API field, not an outbound request parameter. OpenFang **cannot** be
told to serialize tool calls.

**Therefore: if an agent goes silent with this error, change the model. Do not search for a setting —
it does not exist.** Pick a model whose serving template supports parallel tool calls
(`moonshotai/kimi-k2.6` is the VERIFIED-good choice here). Reducing `max_concurrent_tools` does
**not** help — it is a tool-executor concurrency cap, applied *after* the model has already emitted
the multi-call turn (and is itself **SUSPECT: parsed-but-inert**, per seed).

---

## #1195 — slashed model IDs: when it actually bites

UPSTREAM, open, filed against **0.6.9**
(`gh issue view 1195 --repo RightNow-AI/openfang`). Reporter's config:

```toml
[default_model]
provider    = "openai"                 # ← the builtin "openai" provider
model       = "openai/gpt-oss-120b"    # ← namespace == provider name
api_key_env = "FEATHERLESS_API_KEY"
base_url    = "https://api.featherless.ai/v1"
```

```text
Error: Model not found: {"error":{"message":"The model `gpt-oss-120b` does not exist.",
"type":"invalid_request_error","code":"model_not_found"}}
```

OpenFang sent `gpt-oss-120b` instead of `openai/gpt-oss-120b`. **Confirmed workaround in the issue:
`zai-org/GLM-5.1` works with the identical `provider`/`base_url`/`api_key_env`.**

**Read the scope correctly — this is where people over-react.** The bug strips the leading
`<segment>/` **only when that segment matches the provider name** (`provider="openai"` +
`model="openai/..."`). A slashed id whose namespace differs (`zai-org/…`) passes through untouched.
Related: #856 (same rewriting class).

**This install is NOT affected.** `provider = "gonka-1"`, `model = "moonshotai/kimi-k2.6"` —
namespace `moonshotai/` ≠ provider `gonka-1`, so nothing is stripped. (The seed's note *"our
default_model is slashed — same shape"* is **over-cautious and wrong**; the shape that matters is
namespace-equals-provider-name.) Proof: kimi-k2.6 has 20 successful `usage_events` and gonka returns
502/503, never `model_not_found`.

**Rule:** never name a custom provider after the namespace of its own model ids. `gonka-1`/`nim-1`
are safe by construction. `provider = "moonshotai"` + `model = "moonshotai/kimi-k2.6"` would trip it.

---

## Budget & cost tracking are INERT

VERIFIED:

```bash
$ sqlite3 -header ~/.openfang/data/openfang.db \
  "SELECT model, COUNT(*) n, SUM(input_tokens) inp, SUM(output_tokens) outp, SUM(cost_usd) cost
   FROM usage_events GROUP BY model LIMIT 10;"
model|n|inp|outp|cost
minimaxai/minimax-m2.7|44|313759|2968|0.0
moonshotai/kimi-k2.6|20|221347|1575|0.0
```

**Every `cost_usd` is `0.0`** — mechanically, because `cost_usd = tokens × input_cost_per_m`, and
all 129 `custom_models.json` entries carry `input_cost_per_m: 0.0` / `output_cost_per_m: 0.0`.
`/api/budget` returns all `0.0`. `max_hourly_usd` / `max_daily_usd` / `max_monthly_usd` /
`alert_threshold` therefore **can never trigger**.

- **Do not tell the user a USD budget protects them.** It does not, on this install.
- The **only** real throttle is `agent.toml → [resources] max_llm_tokens_per_hour`
  (e.g. `ops` = 50000).
- To make cost tracking live: put real prices in `input_cost_per_m`/`output_cost_per_m` (per **1M**
  tokens) and restart. Gonka/NIM are free-tier here, so `0.0` is arguably *honest* — token counts
  are recorded correctly and are the metric to watch.
- Token waste is real and invisible to budgets: 60 calls = **487 508 input vs 4 351 output**
  (112:1), mostly `[AUTONOMOUS TICK]` concluding "No actionable items" (seed).

The 44 minimax vs 20 kimi split is the fingerprint of the mid-session default switch.

---

## Recipe A — add a model

Goal: make `zai-org/GLM-5.1` usable on the gonka chain.

```bash
# 0. PRE-FLIGHT — every provider alias the model must be reachable through.
grep -E '^provider' ~/.openfang/config.toml          # gonka-1 gonka-2 gonka-3 gonka-4 nim-1

# 1. STOP FIRST — the daemon rewrites custom_models.json on shutdown.
openfang stop
cp ~/.openfang/custom_models.json ~/.openfang/custom_models.json.bak-$(date +%Y%m%d-%H%M)

# 2. Append ONE ENTRY PER PROVIDER ALIAS. (id, provider) is the key.
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path.home()/".openfang/custom_models.json"
d = json.loads(p.read_text())
MODEL = "zai-org/GLM-5.1"
for prov in ["gonka-1", "gonka-2", "gonka-3", "gonka-4"]:      # all four, or fallbacks 404
    if any(e["id"] == MODEL and e["provider"] == prov for e in d):
        continue                                                # no dedupe on merge — don't double-add
    d.append({
        "id": MODEL, "display_name": MODEL, "provider": prov, "tier": "custom",
        "context_window": 200000, "max_output_tokens": 32768,
        "input_cost_per_m": 0.0, "output_cost_per_m": 0.0,
        "supports_tools": True,          # False for embedding models
        "supports_vision": False,        # True only if the model really does images
        "supports_streaming": True,
        "aliases": [],                   # e.g. ["glm5"] for `models set glm5`
        # "model_type": "embedding",     # ONLY for embeddings; omit for chat
    })
p.write_text(json.dumps(d, indent=2))
print("entries:", len(d))                                       # expect 129 -> 133
EOF

# 3. START DETACHED — never pipe `openfang start` to head/grep.
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start
sleep 20

# 4. VERIFY FROM THE BOOT LOG — `models list` will NOT show it.
grep -E 'Model catalog|not found in catalog|Kernel booted' ~/.openfang/daemon-start.log | tail -5
# expect: Model catalog: 338 models, 147 available from configured providers (6 local)
```

**Checklist:** entry per provider alias ✓ · `context_window` truthful (it drives trimming) ✓ ·
`supports_tools:false` on embeddings ✓ · `model_type` omitted for chat ✓ · provider name is one that
actually appears in `config.toml` (else it's an orphan like the removed `nvidia` dup) ✓ · catalog
count rose by exactly the number added ✓.

---

## Recipe B — switch the default model

> ⚠️ **This changes the model for EVERY agent** — all 30 on this install, including the production
> Telegram bot. Every bundled agent ships `provider = "default"` / `model = "default"`
> (VERIFIED: `grep -rh '^provider' ~/.openfang/agents --include=agent.toml | sort | uniq -c` →
> `52 provider = "default"`), so they all inherit `[default_model]`. **If the task is "use model X
> for agent Y", you want [Recipe C](#recipe-c--pin-a-model-to-a-single-agent), not this.**

Goal: gonka-1 default `moonshotai/kimi-k2.6` → `zai-org/GLM-5.1` (already added via Recipe A).

**Do not use `openfang models set`** — its picker is builtin-only and it strips all TOML comments.
Edit by hand.

```bash
# 1. Confirm the target exists for gonka-1 in the catalog file.
python3 -c "
import json; d=json.load(open('$HOME/.openfang/custom_models.json'))
print([(e['id'],e['provider']) for e in d if e['id']=='zai-org/GLM-5.1'])"
# [('zai-org/GLM-5.1','gonka-1'), ('zai-org/GLM-5.1','gonka-2'), ...]  ← must be non-empty

# 2. STOP.
openfang stop
cp ~/.openfang/config.toml ~/.openfang/config.toml.bak-$(date +%Y%m%d-%H%M)

# 3. Edit config.toml. Change `model =` in [default_model] AND in every [[fallback_providers]]
#    block you want to move (nim-1 keeps its own model — it's a different provider).
#    Leave provider/api_key_env/base_url alone.
grep -n 'model = "moonshotai/kimi-k2.6"' ~/.openfang/config.toml     # 5 gonka lines -> edit in place
#    -> model = "zai-org/GLM-5.1"

# 4. START DETACHED.
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start
sleep 20

# 5. VERIFY — the booted line is the receipt.
grep -E 'Kernel booted|Fallback provider configured|Failed to parse config' ~/.openfang/daemon-start.log | head -6
# ✔ Kernel booted (gonka-1/zai-org/GLM-5.1)
```

**Gotchas specific to switching:**
- If you change `[default_model].model` but **not** the `[[fallback_providers]]` entries, the first
  gonka 502 silently downgrades every agent to the old model. Change all of them or none.
- **`Failed to parse config, using defaults`** in the log = your gonka config was dropped entirely
  and the daemon is running on builtin defaults with no keys. Treat as fatal; restore the `.bak`.
- Agent-level pins win over `[default_model]`. Any `agent.toml` with an explicit
  `[model] model = "..."` (not `"default"`) ignores your switch. Check:
  `grep -rL 'model = "default"' ~/.openfang/agents --include="agent.toml" | head`
- **`Agent TOML on disk differs from DB, updating` fires for all 30 agents every boot** — runtime
  changes via `agent set <uuid> model X` are reverted on restart. The **file is the source of
  truth**; never fix a model via `agent set`. (VERIFIED, seed)
- Parallel-tool-call check: if the new model's serving template is single-tool-call only, agents go
  silent with the 500 above. Test with a tool-heavy prompt before declaring success.

---

## Recipe C — pin a model to a single agent

Goal: **only** the `coder` agent uses `zai-org/GLM-5.1`; the other 29 stay on kimi-k2.6.
Prerequisite: the model is registered for the target provider via [Recipe A](#recipe-a--add-a-model).

### ❌ First: `pinned_model` is NOT the answer. It is inert on this install.

Told "make this agent use this model", the obvious key is the root-level `pinned_model` in
`agent.toml` (listed in the manifest schema in `agents.md`). **It parses, it is never read, and
nothing warns you.**
**SETTLED (UPSTREAM + VERIFIED)** — it is read at exactly one site, `kernel.rs:2877`:

```rust
let is_stable = self.config.mode == openfang_types::config::KernelMode::Stable;
if is_stable {
    // In Stable mode: use pinned_model if set, otherwise default model
    if let Some(ref pinned) = manifest.pinned_model {
        info!(agent = %manifest.name, pinned_model = %pinned, "Stable mode: using pinned model");
        manifest.model.model = pinned.clone();
    }
} else if let Some(ref routing_config) = manifest.routing {   // ← [routing] lives in the ELSE
    ...
}
```

Three facts decide it:

1. `pinned_model` is gated behind `config.mode == KernelMode::Stable`.
2. `KernelMode` defaults to `Default` (`config.rs:164`, `#[default] Default`).
3. **This install has no `mode` key.** VERIFIED:
   `grep -nE '^\s*mode\s*=' ~/.openfang/config.toml` → no match. (Beware: a bare `grep '^mode'`
   matches the five `model = ` lines and looks like a hit. It is not.)

⇒ `is_stable` is **false** ⇒ `pinned_model` is **dead code on this box**. Setting it does nothing,
logs nothing, and errors nothing. Corroborating: `grep -rlE '^\s*(pinned_model|\[routing\])'
~/.openfang/agents --include="agent.toml"` → **no agent uses either key**. Upstream `docs/providers.md`
advertises `pinned_model = "claude-sonnet-4-20250514"  # never auto-routed` with **no mention that it
requires Stable mode in practice** — do not trust it.

Two further limits, should anyone ever set `mode = "stable"`: it assigns **`manifest.model.model` only,
never `.provider`** — so `pinned_model` can never move an agent to a different provider; and Stable
mode is an `if/else` against `[routing]`, so **enabling Stable silently disables `[routing]` for every
agent.** Neither is a per-agent knob. **Use `[model]` instead — that is Step 2 below.**

### The one thing that actually works: a concrete `[model]` block

```bash
# 1. STOP. (Same rule as Recipe A: registry is boot-cached, no reload command.)
#    Skip if `curl … /api/health` already returns 000 — it is already down, and `stop`'s audit
#    cost on a down daemon is UNMEASURED (SKILL.md cost tiers).
openfang stop
cp ~/.openfang/agents/coder/agent.toml ~/.openfang/agents/coder/agent.toml.bak-$(date +%Y%m%d-%H%M)
```

**Edit the EXISTING `[model]` block — do not append a second one.** Here is what `coder/agent.toml`
**actually ships** (VERIFIED on disk — note the `api_key_env` line the older version of this recipe
pretended was not there):
```toml
[model]
provider = "default"
model = "default"
api_key_env = "GEMINI_API_KEY"     # ← REALLY THERE. 11 of 30 [model] blocks have one
max_tokens = 8192                  #   (8× GEMINI + 3× DEEPSEEK, VERIFIED). None of those keys
temperature = 0.3                  #   exist in secrets.env.
```
Change it to:
```toml
# 2. ~/.openfang/agents/coder/agent.toml — write BOTH keys, concretely.
[model]
provider = "gonka-1"                        # concrete — NOT "default"
model    = "zai-org/GLM-5.1"                # concrete — NOT "default"
base_url = "https://api.gonkagate.com/v1"   # SET IT — see "base_url: SUSPECT" below
# DELETE the shipped `api_key_env = "GEMINI_API_KEY"` line: the convention resolves
#   gonka-1 -> GONKA_1_API_KEY, and GEMINI_API_KEY does not exist in secrets.env.
#   Leaving it is *probably* harmless (agents.md: `api_key_env` is a hint, not a lock — the
#   lookup misses and the driver chain recovers via the convention) but it is load-bearing
#   reasoning in another file. Delete it and the question does not arise.
max_tokens = 8192       # ← GET THIS RIGHT NOW. After this edit the TOML->DB diff goes permanently
temperature = 0.3       #   quiet and these freeze at their DB values forever (agents.md, "TOML vs DB").
# leave system_prompt untouched
```

🔶 **`base_url`: SUSPECT — but SET IT.** Nothing confirms whether the *agent* driver path consults
`[provider_urls]` or only `[default_model]`, and the overlay does not run when pinned. **On this box
it is redundant-at-worst — `[provider_urls]` maps `gonka-1` to the exact same URL you would type** —
so setting it is strictly safer than depending on the unresolved question. An earlier revision of
this recipe said "NO base_url" while `agents.md` said "set it"; **this recipe is the owner and now
says SET IT.** Say you are unsure rather than presenting either as certain.

⚠️ **If your target agent has its own `[[fallback_models]]` (22 of 30 do) or a concrete
`gemini-2.0-flash` fallback (11 of 30 do), edit that block IN THIS SAME RESTART** — it is not in the
boot diff afterwards, and it will otherwise sit at index 1 naming a model whose key does not exist.

```bash
# 3. START DETACHED — transient service, never `nohup … & disown`, never pipe to head/grep.
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start
sleep 20

# 4. VERIFY. The default must be UNCHANGED — that is the proof you moved one agent, not all 30.
grep -aE 'Kernel booted|Failed to parse config' ~/.openfang/daemon-start.log | tail -3
# expect: ✔ Kernel booted (gonka-1/moonshotai/kimi-k2.6)   ← STILL kimi. Correct.
grep -a 'differs from DB' ~/.openfang/daemon-start.log | grep coder    # coder re-synced from disk
```

**`✔ Kernel booted (...)` reports the *default* model, not `coder`'s.** There is no boot line that
prints a per-agent model, and `driver_index=0` logs an empty `model=` even when pinned
([why](#trap-driver_index0-always-logs-model-empty)).

### How to actually prove a pin took — VERIFIED 2026-07-14

**`GET /api/agents` carries per-agent model fields.** The keys are `model_name`, `model_provider`,
`model_tier` — **not** `model`/`provider`, which is why an earlier pass concluded this read-back was
impossible. It is not.

```bash
curl -s http://127.0.0.1:4200/api/agents | python3 -c "
import sys,json
for x in json.load(sys.stdin):
    print(f\"{x['name']:16} {x.get('model_provider')} / {x.get('model_name')}\")"
```
Real output with `hello-world` pinned to NIM and everything else on the default:
```
hello-world      nim-1 / meta/llama-3.3-70b-instruct
assistant        gonka-1 / moonshotai/kimi-k2.6
coder            gonka-1 / moonshotai/kimi-k2.6
```

**⚠️ But `/api/agents` alone is NOT proof — it reports the manifest's *intent*, not a working
driver.** VERIFIED the hard way: with `model` pinned and `provider = "default"`, `/api/agents`
cheerfully reported `gonka-1 / minimaxai/minimax-m2.7` — while the driver could not be constructed at
all and every call 500'd (see the `&&` guard below). **The API lied.**

**The only conclusive proof is `usage_events` after a real call** — it records what actually served
the request, after the fact:
```bash
sqlite3 ~/.openfang/data/openfang.db \
  "SELECT a.name, u.model, u.input_tokens, u.output_tokens
   FROM usage_events u JOIN agents a ON a.id=u.agent_id
   WHERE a.name='hello-world' ORDER BY u.timestamp DESC LIMIT 3;"
# hello-world|meta/llama-3.3-70b-instruct|9397|22     ← the pin demonstrably served the call
```

**Recommended read-back ladder:** `/api/agents` (fast, but only shows intent) → one real
`openfang message <UUID> "…"` → `usage_events` (conclusive). Do not stop at step 1.

### **You must write BOTH `provider` and `model`. Writing only `model` breaks the agent.**

The inheritance guard is an `&&` — UPSTREAM `kernel.rs:1633-1637` (spawn) and `kernel.rs:1423-1429`
(boot-restore), both identical in shape:

```rust
let is_default_provider = manifest.model.provider.is_empty() || manifest.model.provider == "default";
let is_default_model    = manifest.model.model.is_empty()    || manifest.model.model == "default";
if is_default_provider && is_default_model {  /* overlay [default_model] onto the manifest */ }
```

Set `model = "zai-org/GLM-5.1"` but leave `provider = "default"` and the overlay is skipped entirely
— the **literal string `"default"`** is then handed to the driver factory as a provider name.
`[provider_urls]` has no `default` key, so it resolves to no URL and driver construction fails:

**VERIFIED 2026-07-14 — reproduced end-to-end on this box.** Pinned `hello-world` to
`model = "minimaxai/minimax-m2.7"` while leaving `provider = "default"`, restarted, and sent one real
message. The daemon booted clean (**zero** `driver init failed` lines in the log — the failure is
*lazy*, at first use, not at boot), and the call returned:

```
Boot failed: Agent LLM driver init failed: API error (0): Unknown provider 'default'.
Supported: anthropic, gemini, openai, azure, bedrock, groq, openrouter, deepseek, together,
mistral, fireworks, ollama, vllm, lmstudio, perplexity, cohere, ai21, cerebras, sambanova,
huggingface, xai, replicate, github-copilot, chutes, venice, nvidia, codex, claude-code.
Or set base_url for a custom OpenAI-compatible endpoint.
```

Note what that error list tells you: **`gonka-1` / `nim-1` are not in it.** Those are *custom*
OpenAI-compatible providers, reached via the `base_url` escape hatch named in the last line — which
is why `[provider_urls]` exists. The literal `"default"` is not a provider name and never resolves.

Three traps compound here, and this is the worst-case shape:
- **The boot is silent.** No warning, no `driver init failed` at startup.
- **`/api/agents` reports the pin as if it worked** (`gonka-1 / minimaxai/minimax-m2.7`).
- **The failure only surfaces on the first real message** — possibly days later, possibly on a
  scheduled tick nobody is watching.

It is an `&&`, so **half a pin is worse than no pin.** Write **both** `provider` and `model`.

### **Trap: pinning `coder` does NOT repoint its fallbacks. They still serve the OLD model.**

This is the failure mode most likely to fool you, because **the agent keeps answering** — just not on
the model you pinned. `resolve_driver` composes the chain from three sources (UPSTREAM
`kernel.rs:5681-5684`, verbatim comment):

```
//   1. Primary driver (from the agent manifest)
//   2. Per-agent `manifest.fallback_models` (#845)
//   3. Global `config.fallback_providers` (#1003) — applied to *every* agent
```

Step 3 is the trap: `[[fallback_providers]]` is **global and is not touched by an agent-level pin.**
So `coder` becomes:

⚠️ **Work the index math out for YOUR agent — do not copy a fixed range.** The chain order is
agent `[model]` → agent `[[fallback_models]]` → config `[[fallback_providers]]`, and **22 of 30
agents ship their own `[[fallback_models]]`**, which takes index 1 and shifts everything after it.
Config has **exactly 4** `[[fallback_providers]]` (VERIFIED: `grep -c '^\[\[fallback_providers\]\]'
~/.openfang/config.toml` → `4`) — so a *plain* agent gets a 5-driver chain (0–4) and one with its own
block gets 6 (0–5). This matches the live census: 26 chains ending at 4, 13 ending at 5.

`coder` is one of the 22 (VERIFIED: its `[[fallback_models]]` is `provider="default"`,
`model="default"`, `api_key_env="GROQ_API_KEY"`), so `coder` becomes:

| index | source | model actually used |
|---|---|---|
| 0 | agent `[model]` — your pin | `zai-org/GLM-5.1` ✅ |
| 1 | agent `[[fallback_models]]` (**coder's own** — resolves back to the default) | **`moonshotai/kimi-k2.6`** ❌ |
| 2–4 | config `[[fallback_providers]]` gonka-2/3/4 | **`moonshotai/kimi-k2.6`** ❌ |
| 5 | config `[[fallback_providers]]` nim-1 | **`meta/llama-3.3-70b-instruct`** ❌ |

For an agent **without** its own block (8 of 30: health-tracker · hello-world · home-automation ·
ops · personal-finance · translator · travel-planner · tutor) shift rows 2–5 up by one: gonka-2/3/4
at **1–3**, nim-1 at **4**.

*(An earlier revision printed "1–4 = gonka-2/3/4" — three providers stretched over four indices — and
silently assumed the target had no `[[fallback_models]]`. Wrong for `coder`, its own example.)*

**One gonka-1 502 — routine on this install, see the [fallback chain](#the-fallback-driver-chain) —
and `coder` silently answers on kimi while you believe it is on GLM.** Nothing logs "the pin was
bypassed". Recipe B's version of this hazard is *fixable* (change all five config lines); **the
per-agent case is not**, because those fallbacks are shared with the other 29 agents. You cannot
repoint them without moving everyone.

Your options, honestly stated:

- **Accept it.** Fine when the fallback model is merely *slower/dumber*, not *wrong*. Detect it after
  the fact — this is the query that tells you the truth:
  ```bash
  sqlite3 -header ~/.openfang/data/openfang.db \
   "SELECT model, COUNT(*) n FROM usage_events GROUP BY model LIMIT 10;"
  ```
  A non-zero `moonshotai/kimi-k2.6` count after you pinned means fallbacks fired.
- **Add agent-level `[[fallback_models]]`** (chain step 2, so it runs *before* the global ones) naming
  GLM-5.1 on gonka-2/3/4. **Caveat, and it is a real one:** `fallback_models` is **not** in the boot
  diff list (see the boot-diff field list in `agents.md`), so on an agent whose diff has gone quiet
  the edit is ignored — see the next trap. Adding it *in the same edit* as the `[model]` change
  works, because `model.provider` /
  `model.model` **are** diffed and the manifest merge is total once any diffed field moves.
- **Do not** set `provider = "default"` in a `[[fallback_models]]` block — it resolves to gonka-1
  again and just wastes a round-trip ([why](#trap-chain-length-varies-per-agent--provider--default-duplicates-a-driver)).

### **Trap: pinning permanently silences that agent's TOML→DB diff**

Today all 30 agents re-sync from disk every boot *only because* disk says `"default"` while the DB
holds the post-overlay `"gonka-1"` — a mismatch that is load-bearing but accidental. Writing a
concrete provider (which the `&&` rule **forces** you to do) removes the mismatch. From then on
`coder`'s **undiffed** fields — `temperature`, `max_tokens`, `capabilities.shell`,
`[[fallback_models]]`, `pinned_model` — freeze at their DB values and later edits to them are silently
ignored. Full field list and mechanism: `agents.md` ("TOML vs DB"). **This is a permanent, unavoidable
cost of doing what was asked.** Make the `[model]` edit and any `[[fallback_models]]` edit **in the
same restart**, while the diff still fires.

### Non-traps — do not waste time on these

- ✅ **`api_key_env` clobbering on restart — SETTLED 2026-07-14. It does NOT happen. Cross-family
  pinning is safe.** This was the project's longest-standing open hazard: two references read
  `kernel.rs:1436` opposite ways, and the pessimistic reading was that a restart force-overwrites a
  pin's `api_key_env` and **sends a gonka key to NVIDIA**. **Settled by experiment, not by reading.**

  Method — pinned `hello-world` (a never-used template, 0 usage events, no schedule) fully across the
  key family, restarted, and sent one real message:
  ```toml
  [model]
  provider    = "nim-1"                          # different provider
  model       = "meta/llama-3.3-70b-instruct"    # different model
  api_key_env = "NIM_1_API_KEY"                  # DIFFERENT KEY FAMILY
  ```
  Results, all three checks agreeing:
  ```bash
  # 1. the manifest survived the restart untouched — no clobber
  $ grep -E "provider|api_key_env" agent.toml
  provider = "nim-1"
  api_key_env = "NIM_1_API_KEY"

  # 2. the call succeeded — a wrong (gonka) key against NVIDIA would 401/403
  $ openfang message 2681b967-… "Reply with exactly: PIN-OK"
  PIN-OK

  # 3. usage_events — the conclusive, after-the-fact record
  hello-world | meta/llama-3.3-70b-instruct | in=9397 | out=22
  ```
  That was the **only** `meta/llama-3.3-70b-instruct` call in the install's entire history — so the
  request provably reached NVIDIA NIM, authenticated with the NIM key, and returned.

  **The optimistic reading of `kernel.rs:1436` (assignment INSIDE the guard) is the correct one.**
  `agents.md`'s opposite reading is WITHDRAWN. Pinning across key families is safe — but you must
  still write `provider`, `model` **and** `api_key_env` together (the `&&` guard above).

  *(Historical note, kept so nobody "re-fixes" this back: the old rule read "pin WITHIN the same key
  family (gonka-1..4) to dodge the question entirely" and demanded re-reading `api_key_env` after two
  restarts. That caution was rational while undecided, but it is now obsolete — the experiment above
  settles it. Do not reintroduce it.)*
- **Cross-provider pins work without extra config.** `provider = "nim-1"` +
  `model = "meta/llama-3.3-70b-instruct"` resolves its URL from `[provider_urls]` and its key from
  the `nim-1 → NIM_1_API_KEY` convention. Both already exist here.
- **⚠️ The one exception — `is_auto_spawned` overrides a pin.** Note the Rust precedence:
  `(is_default_provider && is_default_model) || is_auto_spawned`. An agent named exactly `assistant`
  **and** described exactly `"General-purpose assistant"` gets the overlay **even when pinned** — its
  `[model]` is force-reset to the default on every boot-restore. **This install is NOT affected**
  (VERIFIED: `assistant`'s description is `"General-purpose assistant agent. The default OpenClaw
  agent for everyday tasks, questions, and conversations."` — an exact-string `==`, so no match). But
  if pinning `assistant` ever appears not to stick, this is why.

**Checklist:** `pinned_model` NOT used ✓ · **both** `provider` and `model` concrete ✓ · `base_url`
**set** ✓ · the shipped `api_key_env` line **deleted** ✓ · `max_tokens`/`temperature` deliberately
correct (they freeze after this) ✓ · model registered for that provider in `custom_models.json`
(Recipe A) ✓ · stop → edit → start ✓ · `✔ Kernel booted` still names the **old** default ✓ ·
fallback exposure accepted or `[[fallback_models]]` added **in the same restart** ✓ · tool-heavy
prompt exercised (the [parallel-tool-call 500](#the-parallel-tool-call-incompatibility) has no knob) ✓.

---

## Error string → meaning

| Verbatim string | Meaning / action |
|---|---|
| `Fallback driver failed, trying next driver_index=N model=M error=...` | One driver failed. Read the **whole run**; the user-facing error is the **last** index. |
| `driver_index=0 model=` (empty) | Normal. Agent `[model] model = "default"` renders an empty label. Not a misconfiguration. |
| `No drivers configured in fallback chain` | Chain empty — `[default_model]` missing or config fell back to defaults. |
| `Primary model not found, trying ` / `(stream), trying ` | Chain start; primary lookup missed the catalog. |
| `' not found in catalog` | `(id, provider)` pair absent from builtin **+** `custom_models.json`. Usually: model added for `gonka-1` only, chain fell to `gonka-2`. |
| `Model not found: {"error":...,"code":"model_not_found"}` | Provider rejected the id. If `provider=="<namespace>"` of the model → **#1195 stripping**. |
| `This model only supports single tool-calls at once! (in default:95)` | Parallel tool calls unsupported by the serving template. **No knob. Change the model.** |
| `ResourceExhausted: Worker local total request limit reached (24/16)` | gonka 503, `category=Overloaded retryable=true`. Whole chain is one provider → all 4 aliases exhaust together. |
| `API error (502): {"...server had an error..."}` | gonka upstream outage. Hits all `gonka-*` indices at once. |
| `HTTP error: error sending request for url (https://integrate.api.nvidia.com/v1/chat/completions)` | NIM unreachable; `category=Format retryable=false`. 235 audit rows — the last-resort fallback is effectively dead. |
| `Boot failed: Missing API key: Set GROQ_API_KEY` | Boot-validation reading a bundled agent's `[[fallback_models]] api_key_env`. **Inert at runtime** when `provider="default"`. 138 audit rows. Cosmetic. |
| `Failed to parse config, using defaults` | **Fatal-in-effect.** gonka config dropped; daemon running keyless. Restore the `.bak`. |
| `Model not found on Ollama. Run \`ollama pull <model>\` first.` | Embedding/local path — see the memory/embeddings reference. |
| `applied N provider URL override(s)` / `Hot-reload: applying provider URL overrides` | `[provider_urls]` accepted. The one model-adjacent thing that hot-reloads. |
| `Stable mode: using pinned model` | **You will never see this** unless `mode = "stable"` is in `config.toml` (it is not, here). Its absence is the proof `pinned_model` did nothing. Use `[model]` — [Recipe C](#recipe-c--pin-a-model-to-a-single-agent). |
| `Model routing applied` / `Model routing changed provider` | An agent's `[routing]` table overrode its `[model] model` **at spawn**. No agent here sets `[routing]`, so this should never appear; if it does, that agent's pin is being overridden. |
| `Agent LLM driver init failed: ` | Driver construction failed for a **non-default** provider or one with a custom key/url — no silent fallback on that path (`kernel.rs:5675`). Usual cause: `[model] model` set concrete while `provider = "default"` was left alone. |

---

## Quick reference

```bash
# Truth about the merged catalog (boot log — NOT `models list`)
grep -E 'Model catalog|Kernel booted' ~/.openfang/daemon-start.log | tail -2

# Full fallback-chain picture from the log (ANSI must be stripped or greps miss)
sed -E 's/\x1b\[[0-9;]*m//g' ~/.openfang/daemon-start.log \
  | grep -oE 'driver_index=[0-9]+ model=[^ ]*' | sort | uniq -c

# What's actually in the custom catalog
python3 -c "
import json,collections; d=json.load(open('$HOME/.openfang/custom_models.json'))
print(len(d),'entries'); print(collections.Counter(e['provider'] for e in d))"

# Real token spend (cost_usd is always 0.0 — ignore it)
sqlite3 -header ~/.openfang/data/openfang.db \
 "SELECT model,COUNT(*) n,SUM(input_tokens) inp,SUM(output_tokens) outp FROM usage_events GROUP BY model LIMIT 10;"

# Which agents pin a model / add a redundant fallback driver
grep -rl 'fallback_models' ~/.openfang/agents --include="agent.toml" | head -20
```

**MUST NOT:** write `custom_models.json` while the daemon runs · pipe `openfang start` into
`head`/`grep` · use `models list` to verify a custom model · use `openfang models set` or
`config set` on a commented config · use `agent set <uuid> model X` for a durable change · look for
a `parallel_tool_calls` setting · trust `cost_usd`/`/api/budget` · trust upstream
`docs/providers.md` on `fallback_models` **or on `pinned_model`** · use `pinned_model` to pin a model
(inert — `mode` is not `stable`) · set `[model] model` while leaving `provider = "default"` (the guard
is an `&&`) · run Recipe B when the task named **one** agent.

**Always bound greps against this install:** `grep ... ~/.openfang/... | head -N`. Never recursive
from `~` — the home dir is 8.5 GB and unbounded greps have OOM-killed this 15 GB machine twice.
