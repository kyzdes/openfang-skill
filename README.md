# openfang — operator playbook plugin

A Claude Code plugin that encodes hard-won operational knowledge about **OpenFang v0.6.9**, the Rust
"Agent Operating System" (CLI + daemon at `~/.openfang`) that spawns and orchestrates AI agents over
cloud inference.

It exists so an agent never has to rediscover, on your machine and your quota, that
`openfang start` runs in the foreground, that the model registry has no reload command, or that
`openfang mcp` will eat 12 GB of RAM if you run it from a tool call.

## ⚠️ Read this first: upstream is abandoned

**The last commit to [RightNow-AI/openfang](https://github.com/RightNow-AI/openfang) is
2026-05-12 — the same day as the last release, v0.6.9.** That is the version this playbook
documents, and it is terminal. Issues asking "is this maintained?" ([#1240], [#1214]) have gone
unanswered, including the open security reports.

Consequences, stated plainly:
- **No fix is ever coming.** Every workaround here is permanent, not a stopgap.
- Do not file issues upstream. Nobody is reading them.
- Do not wait for a release. There is no upgrade path within OpenFang.

A successor fork exists — [LibreFang](https://github.com/librefang/librefang), actively released.
`references/upstream-state.md` gives an honest migration assessment, including what we do **not**
know about compatibility. It does not recommend migrating just because upstream died.

[#1240]: https://github.com/RightNow-AI/openfang/issues/1240
[#1214]: https://github.com/RightNow-AI/openfang/issues/1214

## What it teaches

`skills/openfang/SKILL.md` is a **router** — it opens with the six traps that cost the most time,
a MUST NOT / CAN block, and a table pointing at the right reference. Depth lives in
`skills/openfang/references/`:

| File | Covers |
|---|---|
| `gotchas.md` | Every trap, ordered by cost: machine-killing → money-burning → hour-burning → cosmetic. Each entry: symptom → root cause → fix → evidence. |
| `daemon-lifecycle.md` | start/stop/restart, the foreground + systemd-oomd traps, boot sequence, cached-vs-hot-reloaded |
| `agents.md` | `agent.toml` schema, workspace files, `[capabilities]` RBAC, creating agents |
| `models-providers.md` | `[default_model]`, fallback chain, `custom_models.json`, adding/switching models |
| `automation.md` | `[schedule]`, cron + fan-out delivery, triggers, workflows, hands, skills |
| `memory-embeddings.md` | `[memory]`, DB tables, the compactor, ollama embeddings |
| `config-reference.md` | Every config key, `secrets.env` vs `.env`, all `OPENFANG_*` env vars |
| `cli-reference.md` | All 40 commands + subcommands, exact signatures, DANGER tags |
| `api-mcp.md` | HTTP API, auth, the trailing-slash 404 trap, the 65 agent tools, MCP |
| `channels.md` | Telegram in depth + the other 43 adapters; silent-bot triage |
| `upstream-state.md` | Abandoned upstream, the operator-relevant issue index, LibreFang |

**Every claim is marked** `VERIFIED` (observed on a live install, with the command and real output),
`UPSTREAM` (from the repo/docs, cited), `SUSPECT` (contradictory evidence — says what would settle
it), or `UNVERIFIED` (untestable — says why). Upstream docs describe intent, not this build; when
docs and the binary disagree, the binary wins.

## Commands

| Command | Does |
|---|---|
| `/openfang-status` | One-glance health: daemon up/down, uptime, agents, provider+model, recent errors, today's tokens. Read-only. |
| `/openfang-doctor` | Runs `doctor --json` and interprets it — including the known false positives it will report. Read-only. |
| `/openfang-restart` | The **safe** restart. Requires explicit intent; it is destructive to running agents. |

## Scripts

- `scripts/diagnose.sh` — read-only. Daemon state, health, provider/model, recent errors,
  heartbeat/crash-recovery counts, token rate, embedding coverage, ollama reachability, recent
  OOM kills. Every command bounded.
- `scripts/safe-restart.sh` — restarts the daemon under `systemd-run --user --unit=openfang` so it survives
  the terminal dying. Refuses unless `OPENFANG_CONFIRM=1`.

## MCP

`.mcp.json` mounts OpenFang's own stdio MCP server (`openfang mcp`), giving the agent live tools
against the install.

**Never run `openfang mcp` yourself from a tool call.** It is a stdio server that never exits; its
output buffers into the host process. That OOM-killed a 15 GB machine at 12.3 GB. Let the MCP client
own its lifetime.

## Install

```
/plugin marketplace add kyzdes/claude-skills
/plugin install openfang@claude-skills
```

Or point a local marketplace at this directory.

## Scope

Written against **one real install** (Ubuntu 26.04, gonka + NVIDIA NIM providers, `kimi-k2.6`,
ollama embeddings, Telegram). Paths and provider specifics in the SKILL.md facts box are that
install's. The mechanics — lifecycle, config schema, RBAC, cron, the traps — are v0.6.9's and apply
anywhere.

NOT for LangChain, CrewAI, AutoGPT, Ollama-as-a-product, or LibreFang.
