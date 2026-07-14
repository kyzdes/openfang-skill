---
allowed-tools: Bash(openfang doctor:*), Bash(ls:*), Bash(grep:*), Bash(export:*), Read
description: Run openfang doctor and interpret it — including the false positives it always reports. Read-only.
disable-model-invocation: false
---

Run OpenFang's diagnostics and **interpret** them. The value of this command is not running
`doctor` — it is knowing which of its complaints are real and which are noise.

```bash
export PATH="$HOME/.openfang/bin:$PATH"
openfang doctor --json 2>&1 | head -60
```

## 🚨 NEVER run `--repair` here

`openfang doctor --repair` mutates state (creates dirs/config, removes `daemon.json`). It is not
part of this command. Only run it if the user explicitly asks, and only after telling them what it
will touch.

## Known FALSE POSITIVES on this install — do NOT "fix" these

`doctor` will confidently report problems that are not problems. Verified on this machine while the
daemon was authenticating and serving perfectly:

| What doctor says | Reality |
|---|---|
| **`.env file not found`** | Correct but irrelevant. This install keeps secrets in `~/.openfang/secrets.env` (mode 0600), not `.env`. The daemon reads it fine. `config set-key` writes `.env` — two secret paths, no cross-awareness. **Do not create `.env`. Do not migrate the secrets.** |
| **`✘ No LLM provider API keys found!`** | Same root cause. `GONKA_1..4_API_KEY`, `NIM_1_API_KEY` and `TELEGRAM_BOT_TOKEN` are all present in `secrets.env`. Verify with `grep -c '=' ~/.openfang/secrets.env` (count only — never print values). |

If you report either of these as an issue to the user, you have made the install worse by wasting
their attention. Say explicitly: *"doctor reports X — that is a known false positive on this
install."*

## What IS worth acting on

| Signal | Meaning | Next step |
|---|---|---|
| `Stale daemon.json found (daemon not running)` | A previous daemon died without cleaning up. **It does NOT block startup** — the start guard validates the pid against a live process and self-heals (`Removing stale daemon info file`). | **Not a `--repair` case — there are none.** Ignore it, or, once `health` is `000` and `pgrep -f 'openfang start'` is empty, `rm ~/.openfang/daemon.json` by hand. → `references/daemon-lifecycle.md`, `gotchas.md` **G24 (retracted)** |
| Missing directories under `~/.openfang` | Real structural damage | `references/daemon-lifecycle.md` |
| Config parse complaints | **Serious.** A malformed `config.toml` does not fail loudly — it silently falls back to defaults (`Failed to parse config, using defaults`), which means no model config and a default listener | `references/config-reference.md` |

## How to report

1. State whether the daemon is up (doctor works with it down — many checks are local).
2. List only the **real** findings.
3. Explicitly name the false positives you filtered out, so the user knows they were checked and
   dismissed on purpose rather than missed.
4. For anything real, point at the reference file — do not improvise a fix.
