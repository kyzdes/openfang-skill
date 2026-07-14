# Daemon lifecycle (OpenFang v0.6.9)

**Read this when:** you need to start, stop, restart, or health-check the OpenFang daemon; when
`openfang` says "Daemon is not running" / "No running daemon found"; when a config or
`custom_models.json` edit needs to take effect; when the daemon dies unexpectedly; when you must
decide whether a diagnostic command is safe to run against the production install.

Scope: `openfang start|stop|status|health|doctor|gateway`, `daemon.json`, the boot sequence, what
is cached vs hot-reloaded, and the cost of a restart. Everything below marked VERIFIED was
observed on this machine (`~/.openfang`, binary `/home/kyzdes/.openfang/bin/openfang`, v0.6.9) on
2026-07-14. UPSTREAM = read from `RightNow-AI/openfang@main` (= v0.6.9, the installed version).

---

## The four things that waste the most time (read first)

1. **`openfang start` runs in the FOREGROUND. Piping it to anything that exits early (`head`,
   `grep -m1`) sends SIGPIPE and kills the daemon.** It is not a fork-and-return launcher; there
   is no `--daemon`/`-d` flag. `openfang gateway start` is the same function — also foreground.
2. **When the daemon is DOWN, `openfang status` boots a full in-process kernel and WRITES to the
   production DB.** VERIFIED: each invocation appends **+9 rows** to the Merkle audit trail and
   re-writes all 30 agent manifests. `openfang status` is *not* a read-only probe. Use
   **`openfang health`** (liveness) or **`openfang doctor --json`** (diagnosis) instead — neither
   boots a kernel.
3. **`nohup … & disown` does NOT protect the daemon.** It stays in your terminal's systemd scope
   (`app-gnome-Alacritty-<n>.scope`). When *anything else* in that scope OOMs, systemd tears down
   the whole scope and the daemon gets SIGTERM. VERIFIED on this machine — see
   [Why nohup+disown is not enough](#why-nohupdisown-is-not-enough-verified).
   **The replacement is a transient systemd _service_ — `systemd-run --user --unit=openfang`
   with NO `--scope`.** If any summary tells you `--scope`, it is wrong: a scope runs as a child of
   your shell and **blocks**, and `openfang start` never exits — so you get a hung tool call and a
   daemon that dies with it. VERIFIED (3.02 s vs 0.01 s) in
   [Correct detached launch](#preferred-a-transient-systemd-service-no-unit-file).
4. **`find_daemon()` reads `~/.openfang/daemon.json` first — no file, no daemon, as far as every
   CLI command is concerned.** If `daemon.json` is missing while the daemon is alive and serving
   on 4200, `openfang stop` prints `No running daemon found` **and exits 0**, and you cannot stop
   it through the CLI. Port scanning is never used as a fallback.

---

## Correct detached launch

### Preferred: a transient systemd **service** (no unit file)

> **It is a transient *service*, NOT a `--scope`.** Any text anywhere that tells you `--scope` is
> **wrong and will hang your tool call** — see the verified proof below. The command has no `--scope`
> in it. Do not add one. *(SKILL.md #1 now carries this exact command; the two must stay byte-identical.)*

**Read the `Linger=no` trap first — it applies to this recipe too**, not just the unit-file one
below. A `--user` transient service is still a `--user` unit: it dies at logout / last session end
and gives no boot-time start. See "Trap: `Linger=no`" in the next section; it is stated once, there,
and governs **both** launch methods.

```bash
systemctl --user reset-failed openfang 2>/dev/null   # only if the unit name is taken or left `failed`
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start
```
**This is the canonical launch command. It appears verbatim in SKILL.md #1, `cli-reference.md`,
`gotchas.md` G2, `models-providers.md` Recipes A/B/C, `memory-embeddings.md`, and
`scripts/safe-restart.sh`. If you find a variant, the variant is the bug.**

This puts the daemon in **its own** cgroup unit, not the terminal's scope, so a terminal-side OOM
cannot take it down, and it gets a fresh `oom_score_adj=0` instead of inheriting `100`.

**Unit-name collision.** `--unit=openfang` **fails outright** if a unit of that name already exists
or is sitting in `failed` state — the likely state after a crash-and-retry loop. `--collect` only
reaps it on *success*. Hence the `reset-failed` line above; it is free and a no-op when unnecessary.

**`--scope` vs no `--scope` — VERIFIED here, and it is the difference between working and hanging:**
```bash
$ /usr/bin/time -f "elapsed=%es" systemd-run --user --scope --unit=probe /bin/sleep 3
Running as unit: probe.scope; ...
elapsed=3.02s          # ← BLOCKED for the full 3s: runs as a CHILD OF YOUR SHELL

$ /usr/bin/time -f "elapsed=%es" systemd-run --user --unit=probe --collect /bin/sleep 3
Running as unit: probe.service; ...
elapsed=0.01s          # ← returned instantly: the systemd USER MANAGER forks it, detached
```
`openfang start` is **foreground and never exits** (see "What NOT to do"). So `--scope` gives you a
tool call that hangs until timeout, and a daemon that is a child of — and dies with — your shell:
**exactly the bug this section exists to prevent.** The service form is the fix.

**Why `-p StandardOutput="truncate:…"`, and the trap it defuses.** The launch method *decides where the
log lives* — nothing else does:

| Launch method | Where the daemon log goes |
|---|---|
| `nohup … > daemon-start.log 2>&1` (condemned) | `~/.openfang/daemon-start.log` |
| `systemd-run` **without** `-p StandardOutput` | **journald only** — `journalctl --user -u openfang` |
| `systemd-run` **with** `-p StandardOutput="truncate:…"` | the named file, as before |

**Adopt the `systemd-run` launch without that flag and `~/.openfang/daemon-start.log` is never
written again.** It freezes at the last `nohup`-era entry — on this box, 796,982 B (≈797 KB) ending
at the `2026-07-14T08:36:41Z` SIGTERM. An operator who then `tail`s it sees a *shutdown* after a
*boot* and concludes the boot hung. It didn't; the file is a fossil. The canonical command keeps the
flag, so `daemon-start.log` stays authoritative and the "Boot sequence" section below (which reads
that file) stays true. **Drop the flag and you must read `journalctl --user -u openfang` instead** —
pick one and know which you picked.

> ### ⏱ Two clocks, one event — read this before comparing any two timestamps
> **`daemon-start.log` lines are UTC** (`2026-07-14T08:36:41Z`). **File mtimes, `journalctl`, and
> `systemd-oomd` are local time = UTC+2** (`10:36:41 +0200`). **The same shutdown reads `08:36:41` in
> the daemon log and `10:36:41` in the journal.** Correlating the two raw puts you exactly 2 h off and
> makes you conclude the events are unrelated — or that there were two shutdowns. There was one.
> The OOM recipe below greps journald with **local** times against a **UTC** log on purpose.
> **Whenever this playbook prints a bare `08:36:41` it means UTC; a bare `10:36:41` means local.**

**Freshness check — never trust a grep of `daemon-start.log` without one.** The file passing a
"success" grep proves nothing if it is a fossil: `curl … /api/health` → `200` first, or bound it with
`stat -c %y ~/.openfang/daemon-start.log`. A stale file will happily "confirm" a boot that never
happened — see `memory-embeddings.md`, where exactly that bug lived.

`StandardOutput="truncate:…"` captures **both** streams. VERIFIED — `StandardError=` defaults to
`inherit`, i.e. it follows `StandardOutput`:
```bash
$ systemd-run --user --unit=probe --collect -p StandardOutput="truncate:$PWD/so.log" \
    /bin/sh -c 'echo THIS_IS_STDOUT; echo THIS_IS_STDERR >&2'
$ cat so.log
THIS_IS_STDOUT
THIS_IS_STDERR
```
This matters because **the daemon's logs are on stderr** (JSON is on stdout — see "Health / status /
doctor"). A bare `> log` redirect **without `2>&1` captures the wrong stream** and gives you an
empty-looking log while the real output goes to your terminal.

Follow the launch with:
```bash
systemctl --user status openfang          # unit state
journalctl --user -u openfang -n 50       # its log (bounded!)
systemctl --user stop openfang            # sends SIGTERM -> graceful shutdown
```

**Verification status.** The `systemd-run` semantics above — service-vs-scope blocking, and
`StandardOutput="truncate:"` capturing both streams — are **VERIFIED on this machine** by the `/bin/sh`
and `/bin/sleep` probes shown (transient probe units, since cleaned up; `openfang` was never
launched). **UNVERIFIED: the full command with `openfang start` has not been executed** — the daemon
is deliberately left down and starting it needs the user's explicit go-ahead (see "What a restart
costs"). The mechanism is standard systemd behaviour and is the direct fix for the VERIFIED failure
below.

### Durable: a `systemd --user` unit

```ini
# ~/.config/systemd/user/openfang.service
[Unit]
Description=OpenFang Agent OS daemon
After=network-online.target

[Service]
Type=simple
ExecStart=/home/kyzdes/.openfang/bin/openfang start
ExecStop=/home/kyzdes/.openfang/bin/openfang stop
Restart=on-failure
RestartSec=10
TimeoutStopSec=30
# The daemon reads secrets from ~/.openfang/secrets.env itself; do NOT duplicate them here.
OOMPolicy=continue
OOMScoreAdjust=-100

[Install]
WantedBy=default.target
```
```bash
systemctl --user daemon-reload
systemctl --user enable --now openfang
```

**Trap: `Linger=no` on this machine — applies to BOTH launch methods above.** VERIFIED:
```bash
$ loginctl show-user kyzdes | grep -i linger
Linger=no
```
With linger off, `user@1000.service` — and therefore **every `--user` unit, transient service and
unit file alike** — is torn down when the last session ends. Neither the preferred `systemd-run
--user` recipe nor this unit file will **survive logout**, and neither gives you boot-time start.
Do not tell the user the daemon is "fixed" without saying this: you have made it survive a
co-tenant OOM, **not** a logout.

Enabling it is a system change (`sudo loginctl enable-linger kyzdes`) — **ask the user before
running it**, it is outside the read-only contract.

**Trap: `Type=simple` + `ExecStop=openfang stop`.** `openfang stop` needs `daemon.json` to find
the daemon. It is written by the daemon itself at startup, so this works — but if you ever run the
daemon with `daemon_info_path = None` (the embedder path used by `openfang-desktop`), `ExecStop`
becomes a no-op and systemd falls back to SIGTERM, which is what you wanted anyway. Harmless.

### What NOT to do

```bash
# WRONG — dies with your terminal's cgroup scope (VERIFIED below)
nohup /home/kyzdes/.openfang/bin/openfang start > ~/.openfang/daemon-start.log 2>&1 & disown

# WRONG — SIGPIPE kills the daemon the moment head exits
openfang start | head -30

# WRONG — same function as `start`, still foreground
openfang gateway start
```

`nohup` only detaches from SIGHUP and the controlling TTY. It does **not** move the process out of
the cgroup, and it does not reset `oom_score_adj`.

---

## Why nohup+disown is not enough (VERIFIED)

On 2026-07-14 the daemon was launched with `nohup … & disown` from an Alacritty terminal. **The
process that ate the memory was the AI agent host itself** — pid 26229, comm `2.1.209`, at
**11.37 GB anon-rss**, running a recursive grep from the 8.5 GB home directory and buffering the
whole result into RAM. See **G1 in `gotchas.md`** — that is *your own tool call*, and it is the
actionable part of this story. The daemon (RSS ~5.5 MB — not the memory hog) was a bystander and
went down with the scope.

```bash
$ journalctl --since "2026-07-14 10:36:30" --until "2026-07-14 10:37:10" --no-pager \
    | grep -aiE "Alacritty-4436|Killed process" | head -5
```
```
Jul 14 10:36:41 kyzdes systemd[2041]: app-gnome-Alacritty-4436.scope: The kernel OOM killer killed some processes in this unit.
Jul 14 10:36:41 kyzdes kernel: [   9353]  1000  9353   153974     1382     1380        2         0   319488     7410          100 openfang
Jul 14 10:36:41 kyzdes kernel: Out of memory: Killed process 26229 (2.1.209) total-vm:17039272kB, anon-rss:11371344kB, ... oom_score_adj:100
Jul 14 10:36:42 kyzdes systemd[2041]: app-gnome-Alacritty-4436.scope: Failed with result 'oom-kill'.
Jul 14 10:36:42 kyzdes systemd[2041]: app-gnome-Alacritty-4436.scope: Consumed 29min 11.857s CPU time over 56min 34.368s wall clock time, 12.5G memory peak, 3.5G memory swap peak.
```

The daemon's own log, same second (`08:36:41 UTC` = `10:36:41` local, UTC+2):
```bash
$ tail -6 ~/.openfang/daemon-start.log | sed 's/\x1b\[[0-9;]*m//g'
```
```
2026-07-14T08:36:41.334925Z  INFO openfang_api::server: Received SIGTERM, shutting down...
2026-07-14T08:36:41.464031Z  INFO openfang_channels::bridge: Shutting down channel adapter telegram
2026-07-14T08:36:41.466817Z  INFO openfang_kernel::kernel: Shutting down OpenFang kernel...
2026-07-14T08:36:41.468459Z  INFO openfang_kernel::supervisor: Supervisor: initiating graceful shutdown
2026-07-14T08:36:41.595694Z  INFO openfang_kernel::kernel: OpenFang kernel shut down (30 agents preserved)
2026-07-14T08:36:41.596005Z  INFO openfang_api::server: OpenFang daemon stopped
```

**The chain:** the **kernel's global OOM killer** kills pid 26229 inside the scope → systemd marks
the *scope* failed with `result 'oom-kill'` → systemd stops the scope → **every surviving process
in it, including the nohup'd, disowned daemon, receives SIGTERM**. `nohup` and `disown` are
irrelevant to cgroup teardown — they detach from SIGHUP and the TTY, nothing else.

**SUSPECT — who pulled the trigger, `systemd-oomd` or the kernel?** Sources disagree and it is
worth 30 seconds to get right, because the two have different fixes. The first journal line reads
`systemd-oomd invoked oom-killer`, which is easy to misread as "systemd-oomd killed the scope under
memory pressure." **The full record says otherwise:**

```
Jul 14 10:36:41 kernel: systemd-oomd invoked oom-killer: gfp_mask=0x140cca(...), order=0, oom_score_adj=-900
Jul 14 10:36:41 kernel: oom-kill:constraint=CONSTRAINT_NONE,...,global_oom,task_memcg=/user.slice/.../app-gnome-Alacritty-4436.scope,task=2.1.209,pid=26229,uid=1000
Jul 14 10:36:41 systemd[2041]: app-gnome-Alacritty-4436.scope: The kernel OOM killer killed some processes in this unit.
```

What settles it, three ways (all VERIFIED, `journalctl --since today | grep -i oom-kill | tail -10`):
1. **`constraint=CONSTRAINT_NONE` + `global_oom`** — this is a *global* kernel OOM (the machine ran
   out of memory outright), **not** a cgroup/pressure kill. A systemd-oomd pressure kill is scoped
   to a cgroup and never logs `global_oom`.
2. **systemd's own message names the culprit**: `The kernel OOM killer killed some processes`.
3. **There are zero `systemd-oomd[…]` pressure-kill lines today.** A real oomd kill logs
   `Killed /user.slice/… due to memory pressure`. Nothing does.

`systemd-oomd` was merely the *allocating task* whose request tripped the global OOM — note its own
`oom_score_adj=-900`, which makes it one of the last things the kernel would ever kill. The two
later OOMs today log `systemd invoked oom-killer` instead, also `global_oom` — **the invoking task
is incidental**; it is whoever happened to ask for a page when memory ran out. **Attribute this to
the kernel's global OOM killer, driven by the agent host's 11.37 GB allocation.** systemd-oomd is a
bystander in the log, not the killer. (`systemd-oomd` *is* `active` on this box and could kill a
scope on pressure — it just didn't do this.)

Two corollaries worth knowing:
- **The daemon inherited `oom_score_adj=100`** from the process tree that launched it (visible in
  the kernel task dump above). A daemon started from a fresh systemd unit gets `0`. Launching from
  an agent/terminal session makes the daemon a *preferred* OOM victim on its own merit.
- **The shutdown was graceful, so no data was lost** — `30 agents preserved`, and `daemon.json` was
  removed by the normal cleanup path. That is why there is no stale `daemon.json` on this machine
  right now. A `SIGKILL`/hard OOM of the daemon itself would leave one behind.

**This will happen again, and the fix does not prevent it — it makes it stop mattering.**
VERIFIED: **three** global OOMs on 2026-07-14, all the same agent-host binary `2.1.209`, all in an
Alacritty scope:

| Time | pid | anon-rss | Scope |
|---|---|---|---|
| 10:36:41 | 26229 | 11.37 GB | `app-gnome-Alacritty-4436.scope` ← **killed the daemon** |
| 10:51:23 | 35348 | 13.59 GB | `app-gnome-Alacritty-27349.scope` |
| 13:27:46 | 207873 | 12.27 GB | `app-gnome-Alacritty-38840.scope` ← the `openfang mcp` incident (`api-mcp.md`) |

Only the first one reached the daemon; it was already down for the other two. Do not read the
transient-service launch below as "the box is now safe" — **the box stays hostile** (15 GB total,
~8.6 GB already in use, and the memory hog is the agent host you are typing into). Moving the
daemon into its own cgroup unit does not reduce the OOM rate by one. It only guarantees the daemon
is no longer collateral when the next one fires. **The OOMs are prevented by G1's discipline
(never recursive-grep from `$HOME`, never run `openfang mcp`), not by anything in this file.**

---

## Health / status / doctor — pick the right one

| Command | Daemon down | Boots a kernel? | Writes to DB? | Exit code | Use it for |
|---|---|---|---|---|---|
| `openfang health` | `✘ Daemon is not running.` | **No** | **No** | **1** down / 0 up | **liveness probe — the only correct one** |
| `openfang health --json` | `{"error":"daemon not running"}` | **No** | **No** | **1** down | scripted liveness |
| `openfang doctor --json` | full check JSON | **No** (0.01 s) | **No** | **0 always** | **diagnosis — parse individual `checks[]`, NOT `all_ok`** |
| `openfang status` | boots in-process kernel | **YES** | **YES (+9 audit rows)** | 0 | *avoid when down* |
| `openfang gateway status` | identical to `status` | **YES** | **YES** | 0 | alias — same trap |

VERIFIED:
```bash
$ openfang health; echo "exit=$?"
  ✘ Daemon is not running.
  hint: Start it with: openfang start
exit=1

$ openfang health --json 2>/dev/null; echo "exit=$?"
{"error":"daemon not running"}
exit=1
```

**`doctor --json` exits 0 even when checks fail.** VERIFIED — never branch on its exit code:
```bash
$ openfang doctor --json > /tmp/doc.json 2>/dev/null; echo "exit=$?"
exit=0
$ head -12 /tmp/doc.json
{
  "all_ok": false,
  "checks": [
    { "check": "openfang_dir", "path": "/home/kyzdes/.openfang", "status": "ok" },
    { "check": "env_file", "status": "warn" },
    { "check": "config_file", "status": "ok" },
    { "check": "daemon", "status": "warn" },
```
**But do NOT gate on `all_ok` either.** It is **permanently `false` on this install** (`rust -> fail`
plus 16 benign `warn`s that can never clear — see the check list below), so this tempting one-liner
**always exits 1 and is useless**:
```bash
# WRONG — always exits 1 here. Looks like a working gate; never passes.
openfang doctor --json 2>/dev/null | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin)["all_ok"] else 1)'
```
**Gate on the specific checks you actually depend on.** VERIFIED to run as written (exit 0,
`core checks ok`, on this install). Do not add an f-string with escaped quotes here — inside the
shell's single-quoted `-c` it is a `SyntaxError`:
```bash
# RIGHT — assert the rows that matter; ignore the permanent warns.
openfang doctor --json 2>/dev/null | python3 -c '
import sys, json
want = {"openfang_dir", "config_file", "config_deser", "database", "agent_manifests", "port"}
bad = [c for c in json.load(sys.stdin)["checks"] if c["check"] in want and c["status"] != "ok"]
for c in bad:
    print("FAIL %s: %s" % (c["check"], c["status"]))
print("core checks ok" if not bad else "%d core check(s) not ok" % len(bad))
sys.exit(1 if bad else 0)'
```
Note `daemon` is deliberately **not** in that set — it is `warn` whenever the daemon is down, which
is a liveness question. Use `health` for that.

**Logs go to stderr; JSON goes to stdout.** VERIFIED — so `2>/dev/null` gives clean, pipeable JSON
from every `--json` command. Without it you get tracing lines interleaved and `jq` fails:
```bash
$ openfang status --json 2>/dev/null
{
  "agent_count": 30,
  "daemon": false,
  "data_dir": "/home/kyzdes/.openfang/data",
  "default_model": "moonshotai/kimi-k2.6",
  "default_provider": "gonka-1",
  "status": "in-process"
}
```
Note `"status": "in-process"`, `"daemon": false` — **that is the daemon-is-down answer.** Also note
`data_dir` is correct in `--json` while the human `status` view prints `Data dir: ?` for the
daemon-up path — prefer `--json` for anything you parse.

### `doctor`'s real check list — re-derived from live output

**Do not trust any earlier write-up of this list, including this file's own previous version.**
VERIFIED by running the command once and parsing it (`openfang doctor --json 2>/dev/null`,
2026-07-14, daemon down): **32 rows, 19 distinct check names**, in this order:

`openfang_dir` · `env_file` · `config_file` · `daemon` · `port` · `database` · `disk_space` ·
`agent_manifests` · `provider` **×11** · `channel` **×4** · `config_deser` · `exec_policy` ·
`bundled_skills` · `skill_injection_scan` · `extensions_available` · `extensions_installed` ·
`rust` · `python` · `node`

**There is no `config_syntax` check. The real name is `config_deser`** — grepping for
`config_syntax` returns nothing. Note also that `config_deser` does **not** sit next to
`config_file`; it lands *after* the 4 `channel` rows. Do not assume adjacency.

`stale_daemon_json` is real but **conditional** — emitted only if the file exists while the daemon
is down. Absent in the down-run above (a clean shutdown removes it).

#### The list CHANGES with daemon state — VERIFIED 2026-07-14, both runs

| Daemon | Rows | Distinct names | Delta |
|---|---|---|---|
| **down** | 32 | **19** | has `port` |
| **up** | **34** | **21** | loses `port`, gains **`daemon_agents`** + **`daemon_db`** |

Live-daemon composition (VERIFIED, `all_ok: false`):
```
openfang_dir · env_file · config_file · daemon · database · disk_space · agent_manifests ·
provider ×11 · channel ×4 · config_deser · exec_policy · bundled_skills · skill_injection_scan ·
extensions_available · extensions_installed · daemon_agents · daemon_db · integration_health ·
rust · python · node
```
- **`port` disappears when the daemon is up** — the port is legitimately bound, by the daemon itself.
- **`daemon_agents` and `daemon_db` only exist when the daemon is up.** `integration_health` is
  present in both. (`daemon_uptime` does **not** exist at all — that name was invented; WITHDRAWN.)
- **`daemon_db` reports the status string `connected`, not `ok`.** So `select(.status!="ok")` flags it
  as a problem when it is fine. Filter for `warn`/`fail` explicitly, not for "not ok".

#### What `all_ok: false` actually means here — VERIFIED, and it is 100% noise

15 `warn` + 1 `fail` on a **healthy** box:
- **11 × `provider -> warn`** — Groq, OpenRouter, Anthropic, OpenAI, DeepSeek, Gemini, Google,
  Together, Mistral, Fireworks, AWS Bedrock. All unconfigured, none used. `doctor` is blind to
  `gonka-*` / `nim-1` (G20), so it warns about the providers you do not have and stays silent about
  the ones you do.
- **3 × `channel -> warn`** — `Discord (DISCORD_BOT_TOKEN not set)`, `Slack App`, `Slack Bot`.
  **Telegram is the 4th channel row and it passes: `✔ Telegram (TELEGRAM_BOT_TOKEN)`.** An earlier
  audit worried these three warnings implicated the live Telegram bot. **They do not.**
- **1 × `env_file -> warn`** — `.env file not found`. The known false positive: secrets live in
  `secrets.env`. Do not "fix".
- **1 × `rust -> fail`** — `✘ Rust toolchain not found`. The **only** `fail`, and it is expected:
  `rust` is needed to *build* things, not to run the daemon. Python 3.14.4 and Node v24.18.0 pass.

**Therefore `all_ok: false` is the normal, healthy state of this install.** Do not treat it as a
signal. Parse the individual rows.

Enumerate it yourself rather than trusting prose:
```bash
openfang doctor --json 2>/dev/null | python3 -c 'import sys,json;[print(c["check"],c["status"]) for c in json.load(sys.stdin)["checks"]]'
```

**`rust -> fail` is the ONLY `fail` on this install.** VERIFIED — every other row is `ok` or `warn`:
```
{"check": "rust", "status": "fail"}
```
`rust`/`python`/`node` are toolchain-presence checks. VERIFIED: no `rustc`, no `cargo`, no
`~/.cargo` — while `python3` and `node` v24.18.0 are present and both report `ok`. So the `fail`
is simply "no Rust toolchain". **This install does not need one — the `openfang` binary ships
compiled. Benign; do not "fix" it by installing Rust** (it would only matter for building an
extension from source).

**Do not read `rust` as the *cause* of `all_ok: false`** — that is UNVERIFIED. Only one `fail` and
several `warn`s are observable; whether `all_ok` is ANDed over `ok`-only or tolerates `warn` is not
determinable from output alone, and the `warn`s (`env_file`, `daemon`, 11×`provider`, 3×`channel`)
would each be sufficient on their own. Settle it by reading `fn cmd_doctor` UPSTREAM if you ever
need to care. **You do not need to care: `all_ok` is permanently `false` here either way, so never
gate on it** — parse the individual `checks[]` rows you actually depend on.

**Known false alarms — all VERIFIED here, all benign:**

- **`env_file -> warn`** — `doctor` looks for `~/.openfang/.env`; this install keeps its keys in
  `~/.openfang/secrets.env` (0600), which the daemon reads correctly. See `cli-reference.md`
  §"`doctor` looks for the wrong secrets file".
- **`provider -> warn` ×11** — every one of the 11 hardcoded providers warns (`Groq`, `OpenRouter`,
  `Anthropic`, `OpenAI`, `DeepSeek`, `Gemini`, `Google`, `Together`, `Mistral`, `Fireworks`,
  `AWS Bedrock`). **`doctor` does not know gonka exists**, which is the provider this install
  actually uses. All 11 warns are expected and permanent.
- **`channel -> warn` ×3 of 4** — previously undocumented, and the one that matters on a box whose
  headline feature is a live Telegram bot. The **Telegram row is `ok`**; only the unconfigured
  channels warn:
  ```
  {"check": "channel", "env_var": "TELEGRAM_BOT_TOKEN", "name": "Telegram", "status": "ok"}
  {"check": "channel", "env_var": "DISCORD_BOT_TOKEN",  "name": "Discord",  "status": "warn"}
  {"check": "channel", "env_var": "SLACK_APP_TOKEN",    "name": "Slack App","status": "warn"}
  {"check": "channel", "env_var": "SLACK_BOT_TOKEN",    "name": "Slack Bot","status": "warn"}
  ```
  **The 3 warns mean "Discord/Slack not configured", not "Telegram is broken."** If you are
  triaging the bot, `channel -> warn` is not your signal — check the Telegram row specifically.
- **`daemon -> warn`** — just means the daemon is down. It is `warn`, never `fail`, so
  `all_ok` cannot be used to detect an outage. Use `health` (see the table above).

Rows carry different keys depending on the check — `port` has `address`, `provider`/`channel` have
`env_var` + `name`, `exec_policy` has `mode` + `safe_bins`. **Only `check` and `status` are
universal.** Key on those.

### The in-process kernel boot — measured

VERIFIED. `openfang status` with the daemon down:
```bash
$ sqlite3 ~/.openfang/data/openfang.db "SELECT COUNT(*) FROM audit_entries;"
851
$ openfang status --json > /tmp/s.txt 2>&1
$ sqlite3 ~/.openfang/data/openfang.db "SELECT COUNT(*) FROM audit_entries;"
860
```
**+9 rows per invocation**, permanently, into a hash-chained Merkle trail. They are the bundled
hands being re-registered:
```bash
$ sqlite3 ~/.openfang/data/openfang.db \
    "SELECT seq,action,substr(detail,1,50) FROM audit_entries ORDER BY seq DESC LIMIT 3;"
886|ConfigChange|HAND.toml load hand=infisical-sync sha256=2619f28e
885|ConfigChange|HAND.toml load hand=trader sha256=db095936c4105
884|ConfigChange|HAND.toml load hand=browser sha256=8bcc61ce9dc99
```
The same run also emits `Agent TOML on disk differs from DB, updating` ×30 and
`Restored 30 agent(s) from persistent storage` — i.e. it executes
`UPDATE agents SET manifest = ?1 WHERE id = ?2` for all 30 agents.

**Five commands fall back to `boot_kernel()` when the daemon is down** (UPSTREAM, `main.rs`
callsites): `status`, `agent list`, `agent new`, `agent spawn`, `agent kill`. All five therefore
mutate the DB when the daemon is down. **`openfang agent list` is not read-only with the daemon
down.** When the daemon is *up*, all of them go over HTTP and are cheap — `cmd_status` calls
`find_daemon()` first and only falls back on `None`.

---

## `daemon.json` — the single source of truth for "is it running?"

UPSTREAM `crates/openfang-api/src/server.rs`:
```rust
/// Daemon info written to `~/.openfang/daemon.json` so the CLI can find us.
pub struct DaemonInfo {
    pub pid: u32,
    pub listen_addr: String,
    pub started_at: String,
    pub version: String,
    pub platform: String,
}
```
Written at startup, `chmod 0600`, and **removed on graceful shutdown**. VERIFIED absent right now
(the last stop was a clean SIGTERM):
```bash
$ ls ~/.openfang/daemon.json
ls: cannot access '/home/kyzdes/.openfang/daemon.json': No such file or directory
```

`find_daemon()` (UPSTREAM) is the gate for every daemon-facing CLI command:
1. read `~/.openfang/daemon.json` → `None` ⇒ **"daemon not running"**, full stop. No port probe.
2. `listen_addr`, with `0.0.0.0` rewritten to `127.0.0.1` (macOS hang workaround).
3. `GET http://{addr}/api/health`, 1 s connect / 2 s total timeout. Non-2xx ⇒ "not running".

**This is the failure mode to remember: a live daemon with no `daemon.json` is invisible to the
CLI.** Recover by talking to the API directly or by PID:
```bash
curl -s http://127.0.0.1:4200/api/health          # is something actually serving?
ss -ltnp | grep 4200                              # who owns the port
pgrep -a openfang
# last resort, if the CLI refuses to see it:
curl -s -X POST http://127.0.0.1:4200/api/shutdown   # graceful, same path `openfang stop` uses
```

### Stale `daemon.json` does NOT block `start` — correcting a common belief

UPSTREAM `server.rs`, the startup guard:
```rust
if is_process_alive(info.pid) && is_daemon_responding(&info.listen_addr) {
    return Err(format!("Another daemon (PID {}) is already running at {}", info.pid, info.listen_addr).into());
}
// Stale PID file (process dead or different process reused PID), remove it
info!("Removing stale daemon info file");
let _ = std::fs::remove_file(info_path);
```
Start refuses **only if both** the PID is alive **and** something accepts TCP on `listen_addr`.
Otherwise it logs `Removing stale daemon info file`, deletes it, and starts normally.
**`openfang doctor --repair` is not required to recover from a stale `daemon.json`** — `start`
self-heals. `doctor` merely *reports* it:
> `Stale daemon.json found (daemon not running). Run with --repair to clean up.`

and `--repair` removes it (`Removed stale daemon.json`). Cosmetic.

**Real edge case (UPSTREAM, from the code comment): PID reuse.** `is_daemon_responding()` is a bare
500 ms TCP connect — *any* listener on 4200 counts, not just OpenFang. If an unrelated process
inherited the dead daemon's PID **and** anything is listening on 4200, `start` will refuse with
`Another daemon (PID <n>) is already running at <addr>`. Verify with `ss -ltnp | grep 4200` before
believing it, then `rm ~/.openfang/daemon.json`.

What *does* block start: the port genuinely being in use → bind fails. `SO_REUSEADDR` is set, so
TIME_WAIT from a previous instance is not a problem; only a live listener is.

### `doctor --repair` — DANGER, and what it actually does

UPSTREAM-verified scope. It will:
- create `~/.openfang/` + `data/` + `agents/` if missing (**prompts** `Create it now? [Y/n]`);
- `chmod 0600` a loose `~/.openfang/.env`;
- **create a default `config.toml` if and only if none exists** (**prompts**
  `Create default config? [Y/n]`), populated from `detect_best_provider()` — i.e. a *different*
  provider than the configured `gonka-1`;
- remove a stale `daemon.json`.

It does **not** overwrite an existing `config.toml`. The two real hazards:
1. **It is interactive.** `prompt_input()` reads stdin. In a non-TTY/agent context it will hang or
   consume input you did not mean to give it. **Never run `--repair` non-interactively.**
2. **If `config.toml` is ever absent or renamed, `--repair` silently generates a stub pointing at
   an auto-detected provider**, quietly replacing this install's gonka/kimi setup. Given the
   `config.toml.bak*` files in `~/.openfang/`, a rename is a plausible accident here.

**Do not run `openfang doctor --repair` against this install.** `openfang doctor --json` gives you
every finding with zero side effects; fix things by hand.

---

## Stop

```bash
openfang stop            # graceful; exits 0 even when nothing was running
```
UPSTREAM `fn cmd_stop()`, exactly:
1. `find_daemon()` → `None` ⇒ print and return **(exit 0)**:
   ```
     - No running daemon found
       try: Is it running? Check with: openfang status
   ```
   VERIFIED. **Ignore that hint — `openfang status` boots a kernel and writes to the DB. Use
   `openfang health`.**
2. `POST {base}/api/shutdown`.
3. Poll `find_daemon()` every 500 ms, **10 times = 5 s**.
4. Gone → `Daemon stopped`.
5. **Still alive after 5 s → `kill -9 <pid>` (SIGKILL), delete `daemon.json`, print
   `Daemon stopped (forced)`.**

**Trap: the 5-second forced-kill escalation.** If shutdown takes longer than 5 s — 30 agents, a
mid-flight LLM call, a WAL checkpoint — `openfang stop` **SIGKILLs it**. There is no
`--timeout`/`--force` flag to tune this. `Daemon stopped (forced)` in the output means the
graceful path did **not** complete: assume in-flight sessions were cut and the WAL was not
checkpointed. If you need a guaranteed-clean stop, send SIGTERM yourself and wait:
```bash
PID=$(python3 -c 'import json;print(json.load(open("/home/kyzdes/.openfang/daemon.json"))["pid"])')
kill -TERM "$PID"
while kill -0 "$PID" 2>/dev/null; do sleep 1; done   # graceful shutdown took ~0.3 s here
```
VERIFIED graceful shutdown duration on this install: **~261 ms**
(`08:36:41.334` SIGTERM → `08:36:41.596` `OpenFang daemon stopped`). The 5 s budget is normally
ample; it is the loaded/hung case that bites.

Three shutdown triggers, all identical downstream (UPSTREAM `shutdown_signal()`):
`SIGINT (Ctrl+C)` · `SIGTERM` · `POST /api/shutdown`. Log lines to grep for:
`Received SIGINT (Ctrl+C), shutting down...` · `Received SIGTERM, shutting down...` ·
`Shutdown requested via API, shutting down...`

Shutdown order: axum graceful drain → delete `daemon.json` → stop channel bridges →
`kernel.shutdown()` → `OpenFang daemon stopped`.

---

## `gateway` is a pure alias

VERIFIED (`--help`) and UPSTREAM (`main.rs` dispatch):
```rust
GatewayCommands::Start  => cmd_start(cli.config, false),
GatewayCommands::Stop   => cmd_stop(),
GatewayCommands::Status { json } => cmd_status(cli.config, json),
```
`openfang gateway start` == `openfang start` **without `--yolo`** (the flag does not exist on the
gateway variant). It is still foreground, and `gateway status` inherits the in-process-boot trap
verbatim. The subcommand buys you nothing except that it cannot be given `--yolo` by accident.

---

## Boot sequence (VERIFIED — real log)

Source: `~/.openfang/daemon-start.log`. **Never `cat` it — it was 797 KB for a single 41-minute
session** (`nohup … > log` truncates on each start, so it holds exactly one run). Use
`head -N` / `tail -N` / `grep … | head`, and strip ANSI with `sed 's/\x1b\[[0-9;]*m//g'`.

`head -60 ~/.openfang/daemon-start.log`, in order:

| # | Stage | Log line (abridged) |
|---|---|---|
| 1 | Config | `Loaded configuration path=/home/kyzdes/.openfang/config.toml` |
| 2 | Kernel | `Booting OpenFang kernel...` |
| 3 | Fallbacks | `Fallback provider configured provider=gonka-2 model=moonshotai/kimi-k2.6` (×4: gonka-2,3,4, nim-1) |
| 4 | Provider URLs | `applied 5 provider URL override(s)` |
| 5 | Model catalog | `Model catalog: 334 models, 143 available from configured providers (6 local)` |
| 6 | Skills | `Loaded 61 bundled skill(s)` |
| 7 | Hands | `Loaded bundled hand hand=clip … sha256=c10ff2b5…` (×9) → `Loaded 9 bundled hand(s)` |
| 8 | Extensions | `Extension registry: 25 templates available, 0 installed` |
| 9 | Embeddings | `Embedding driver configured from memory config provider=ollama model=mxbai-embed-large` |
| 10 | Cron | `Loaded cron jobs from disk count=0` |
| 11 | Audit | `Audit trail loaded: 564 entries, chain integrity OK` |
| 12 | **Agent sync** | `Agent TOML on disk differs from DB, updating agent=<name>` **×30** |
| 13 | Registry | `Restored 30 agent(s) from persistent storage` |
| 14 | Done | `OpenFang kernel booted successfully` |
| 15 | Heartbeat | `Heartbeat monitor started (interval: 30s)` |
| 16 | Consolidation | `Memory consolidation scheduled every 24 hour(s)` |
| 17 | Background | `Starting periodic background loop agent=ops cron=every 5m interval_secs=300` |
| 18 | Triggers | `Registered proactive triggers agent=security-auditor` |
| 19 | Background | `Starting continuous background loop agent=orchestrator interval_secs=120` |
| 20 | Channels | `Telegram bot @OpenAPIModelsBot connected` → `cleared webhook, polling mode active` → `registered 27 bot commands` → `telegram channel bridge started` |
| 21 | **API up** | `OpenFang API server listening on http://127.0.0.1:4200` |
| 22 | Background | `Starting periodic background loop agent=health-tracker cron=every 1h interval_secs=3600` |
| 23 | Ready | `Started 4 background agent loop(s) (staggered)` |

**Timing (VERIFIED):** config load `07:55:06.368` → kernel booted `07:55:07.406` → **API listening
`07:55:08.057`** → background loops staggered in by `07:55:08.911`. **Kernel ~1.04 s, API up at
~1.7 s, fully settled at ~2.5 s.** Poll for readiness rather than sleeping blind:
```bash
for i in $(seq 30); do openfang health >/dev/null 2>&1 && { echo up; break; }; sleep 1; done
```

The banner printed to the terminal on a successful start:
```
  ✔ Kernel booted (gonka-1/moonshotai/kimi-k2.6)
  ✔ 334 models available
  ✔ 30 agent(s) loaded

  API:         http://127.0.0.1:4200
  Dashboard:   http://127.0.0.1:4200/
  Provider:    gonka-1
  Model:       moonshotai/kimi-k2.6

  hint: Open the dashboard in your browser, or run `openfang chat`
  hint: Press Ctrl+C to stop the daemon
```
`hint: Press Ctrl+C to stop the daemon` is the CLI telling you, correctly, that this is a
foreground process.

---

## Cached at boot vs hot-reloaded

**Hot-reloaded (no restart needed)** — the daemon watches `config.toml`:
`Config file changed, reloading...` → `Config hot-reload: no actionable changes` when nothing it
tracks moved. The `config_reload` subsystem detects `memory` / `network` / `vault` / `api_listen`
changes; `secrets.env` is re-read for channels (`Reloaded secrets.env for channel hot-reload` →
`Channel hot-reload complete`). Explicit reload endpoints exist: `POST /api/config/reload`,
`/api/channels/reload`, `/api/skills/reload` (all POST — **out of bounds for a read-only pass**).
Caveat (UPSTREAM): `provider_api_keys` changes "take effect on next driver init", not immediately.

**Cached at boot — a restart is the ONLY way to apply:**
- **`custom_models.json`** — the model registry is built once at step 5. There is **no**
  `models reload` command. Editing the file does nothing until restart.
- **Bundled skills (61)** and **bundled hands (9)** — compiled into the binary, registered at boot.
- **`cron_jobs.json`** — read once at step 10.
- **Fallback provider chain** and **provider URL overrides** — steps 3–4.
- **Embedding driver** — step 9.
- **Agent manifests** — step 12 (see below).

**Trap: the daemon may rewrite `custom_models.json` on stop.** Safe sequence is therefore
**stop → copy the fixed file in → start**, never edit-then-stop:
```bash
openfang stop
sleep 2
cp ~/.openfang/custom_models.json.fixed ~/.openfang/custom_models.json
# then start detached (see above)
```

---

## What a restart costs

Every boot, VERIFIED on this install:

1. **`Agent TOML on disk differs from DB, updating` fires for all 30 agents.** Not a warning about
   your edits — it fires on *every* boot, unconditionally, for every agent. The comparison never
   converges. The DB manifest is overwritten from `agents/<name>/agent.toml`
   (`UPDATE agents SET manifest = ?1 WHERE id = ?2`).
   **Consequence: any runtime-only change — e.g. `openfang agent set <uuid> model <x>` — is
   reverted on the next restart.** Persist changes by editing `agents/<name>/agent.toml`, not
   through the API/CLI.
2. **+9 audit rows** (the 9 `HAND.toml load` `ConfigChange` entries) into the Merkle chain.
   Audit grew 564 → 842 → 887 → **986** across this project's boots and in-process kernel
   invocations. The 887 → 986 delta is **99 = 11 × 9**: eleven in-process kernel boots, by
   operators running `status` while the daemon was down. **This is the trap costing real rows in
   production** — the count only ever goes up, and the chain is hash-linked, so it cannot be
   cleaned. Irreversible but harmless. See `cli-reference.md` §"Which commands boot a kernel".
3. **30 agents re-spawned**, 4 background loops restarted (staggered ~500 ms apart): `ops`
   (every 5 m), `orchestrator` (continuous 120 s), `health-tracker` (every 1 h), plus
   `security-auditor`'s proactive triggers.
4. **`session_repair` runs.** **Correction to a common claim: it does not only fire at boot** — it
   runs on *every agent loop start*, all day. VERIFIED:
   ```
   07:57:08 WARN openfang_runtime::session_repair: Session repair applied fixes orphaned=0 empty=0 merged=1 reordered=0 synthetic=0 duplicates=0
   08:00:08 WARN openfang_runtime::session_repair: Dropping leading assistant turn(s) to ensure history starts with user dropped=1
   08:00:08 WARN openfang_runtime::session_repair: Session repair applied fixes orphaned=1 empty=1 merged=0 reordered=0 synthetic=0 duplicates=0
   08:01:08 WARN openfang_runtime::session_repair: Session repair applied fixes orphaned=1 empty=0 merged=0 reordered=0 synthetic=0 duplicates=0
   ```
   It mutates history: drops leading assistant turns, merges consecutive same-role messages,
   removes aborted assistant messages, prunes heartbeat `NO_REPLY` turns. It is lossy by design.
5. **Immediate LLM spend.** `orchestrator`'s continuous loop fires ~120 s after boot and `ops`
   every 5 min thereafter. A restart is not free — it re-arms 288 `ops` runs/day.
6. **Telegram re-registration**: webhook cleared, polling re-established, 27 commands re-registered.
   Expect a burst of `Telegram getUpdates network error … retrying in 1s/2s/4s/8s` on a flaky link
   — VERIFIED here at boot, self-heals with backoff.

**Do not restart casually.** There is no cheaper way to reload `custom_models.json`, but everything
in `config.toml` and `secrets.env` is hot-reloaded — check whether you actually need a restart.

---

## Safe restart recipe

Read-only pre-flight, then the minimum mutation. **Never run this against a production install
without the user's explicit go-ahead** — it re-spawns 30 agents and starts spending tokens.

```bash
set -eu
OF=/home/kyzdes/.openfang/bin/openfang
LOG=/home/kyzdes/.openfang/daemon-start.log

# 1. Pre-flight — no side effects
$OF doctor --json 2>/dev/null | python3 -m json.tool | head -40
$OF health || echo "(daemon already down — expected)"

# 1b. SHOULD you restart at all? `doctor` CANNOT answer this — it is blind to custom providers and
#     secrets.env (G20), so it cannot see a 502ing gonka. Restarting into a dead chain re-arms 288
#     ops runs/day against it. Check the chain BEFORE deciding:
sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -c 'Fallback driver failed'   # non-zero => chain was dead
#     Non-zero: probe the provider and repoint it NOW, while you are already stopped (step 4).
#     -> models-providers.md "Every provider is dead at once"

# 2. Snapshot the DB. `.backup` is correct whether or not a WAL exists — it checkpoints for you.
#    Do NOT `cp` the .db alone: if a WAL exists you get a stale snapshot. (See the WAL note below.)
sqlite3 /home/kyzdes/.openfang/data/openfang.db ".backup '/tmp/openfang-$(date +%s).db'"

# 3. Stop, and confirm it is really gone (do NOT trust exit 0)
$OF stop
for i in $(seq 15); do $OF health >/dev/null 2>&1 || break; sleep 1; done
$OF health && { echo "STILL UP — investigate, do not proceed"; exit 1; }
pgrep -a openfang || echo "no openfang process — good"

# 4. Now make your on-disk edits (custom_models.json, agents/*/agent.toml, ...)

# 5. Start detached, in its OWN cgroup unit — not the terminal's. THE CANONICAL COMMAND.
#    Transient SERVICE: no --scope (--scope blocks and re-parents to this shell).
#    -p StandardOutput keeps daemon-start.log authoritative; drop it and the log moves to journald.
systemctl --user reset-failed openfang 2>/dev/null   # --unit=openfang fails if the name is taken
systemd-run --user --unit=openfang --collect \
  -p StandardOutput="truncate:$HOME/.openfang/daemon-start.log" -p StandardError=inherit \
  ~/.openfang/bin/openfang start

# 6. Wait for readiness — poll, never sleep blind
UP=0
for i in $(seq 30); do $OF health >/dev/null 2>&1 && { echo "up after ${i}s"; UP=1; break; }; sleep 1; done

# 7. Verify the boot, bounded. NEVER cat this file. GUARDED: `status` on a DOWN daemon boots an
#    in-process kernel and writes +9 irreversible audit rows — the exact thing this file prevents.
if [ "$UP" = 1 ]; then
  grep -aE 'Kernel booted|Failed to parse config|Telegram bot .* connected' "$LOG" | tail -3
  $OF status --json 2>/dev/null | head -20   # cheap ONLY because health=200: a GET, not a kernel boot
else
  echo "did NOT come up — do NOT run \`status\`; read the log instead:"
  grep -aE 'Failed to parse config|panic|Address already in use' "$LOG" | tail -5
fi
```

**Step 7 is guarded on purpose.** Step 6 can simply time out, and an unguarded `$OF status` on the
failure path is the single most expensive mistake available here. The guard belongs *in the script* —
prose telling you to "check `health` first" does not survive copy-paste.

**Step 7 greps `$LOG` because step 5 kept `-p StandardOutput`.** Drop that flag and you must read
`journalctl --user -u openfang` instead. The two are alternatives, not both. See the log-location
table under "Correct detached launch" — and the freshness rule: a grep of a stale `$LOG` will
"confirm" a boot that never happened.

### The WAL: do not expect one at this point in the procedure

**VERIFIED 2026-07-14, daemon down — there is no WAL file at all:**
```bash
$ ls -la ~/.openfang/data/
-rw-r--r-- 1 kyzdes kyzdes 995328 Jul 14 13:57 openfang.db
```
`openfang.db` is **995328 B (972 KB)**, and **no `-wal` and no `-shm` file exists.** `journal_mode`
is `wal`, but the graceful shutdown fully checkpointed and removed them. (Earlier revisions of this
file quoted "WAL is 733 KB vs 790 KB DB" — **both numbers are stale and the WAL is gone entirely**;
the DB also grows every time something boots an in-process kernel, so treat any byte count here as
a snapshot, not a constant.)

**Why this matters at step 2:** a WAL only exists while the daemon is *running* or after an
*unclean* stop. Step 3 has already stopped the daemon, so by the time you reach the snapshot in a
clean run there is usually **nothing to checkpoint** — that is expected, not a sign something broke.
Do not go hunting for a missing WAL.

`sqlite3 .backup` remains the right call regardless: it is correct with a WAL, without one, and
against a live daemon, so it needs no branching. **A WAL present here is itself a signal** — it means
either the daemon is still up (re-check `health` before touching anything) or the last stop was
unclean (`stop` SIGKILLs on timeout — see "Stop"). In that case the `-wal` file holds committed
transactions that are not yet in the `.db`, and `cp`ing the `.db` alone silently loses them.

---

## Error strings worth grepping

Verbatim from the binary / logs. All are greppable:

| String | Means |
|---|---|
| `Another daemon (PID <n>) is already running at <addr>` | `daemon.json` PID alive **and** something on `listen_addr`. Check `ss -ltnp \| grep 4200` — may be PID reuse. |
| `Removing stale daemon info file` | `start` self-healed a stale `daemon.json`. Informational. |
| `Stale daemon.json found (daemon not running). Run with --repair to clean up.` | `doctor` only. Cosmetic — `start` handles it itself. |
| `- No running daemon found` | `find_daemon()` returned `None`. Either genuinely down **or** `daemon.json` is missing while the daemon lives. **Exit code is 0.** |
| `Could not reach daemon: <err>` | `daemon.json` existed and `/api/health` answered, but `POST /api/shutdown` failed. |
| `Shutdown request failed (<status>)` | `/api/shutdown` returned non-2xx. |
| `Daemon stopped (forced)` | **Graceful shutdown exceeded 5 s → SIGKILL.** Assume unclean WAL/sessions. |
| `Received SIGTERM, shutting down...` | Someone/systemd stopped it. If unexpected → check `journalctl … \| grep -i oom \| tail -20`. |
| `OpenFang kernel shut down (30 agents preserved)` | Clean shutdown, state persisted. |
| `Failed to parse config, using defaults` | **Silent degradation to defaults — your whole config is being ignored.** |
| `Database error (file may be locked)` | Two kernels at once (often a stray in-process `status`/`agent list` racing the daemon). |
| `Agent TOML on disk differs from DB, updating` | Every boot, ×30. Normal. Means DB manifests get overwritten from disk. |

---

## Hard rules

**MUST NOT**
- Pipe `openfang start` / `openfang gateway start` into `head`/`grep -m1`/anything short-lived.
- Launch the daemon with plain `nohup … & disown` and consider it safe.
- Run `openfang status` / `agent list` / `agent new` / `agent spawn` / `agent kill` as a
  "read-only check" while the daemon is down — they boot a kernel and write to the DB.
- Run `openfang doctor --repair` non-interactively, or at all against this install.
- Trust `openfang stop`'s exit code, or `doctor --json`'s exit code.
- `cat ~/.openfang/daemon-start.log` (797 KB for one session).

**CAN**
- `openfang health` — the only free, correct liveness probe. Exit 1 = down.
- `openfang doctor --json 2>/dev/null` — full diagnosis, zero side effects, gate on `all_ok`.
- `GET http://127.0.0.1:4200/api/health` · `/api/status` — when the daemon is up.
- `tail`/`head`/`grep … | head` on `daemon-start.log`.
- `sqlite3 … "SELECT … LIMIT N"` on `data/openfang.db`.
- `ss -ltnp | grep 4200` · `pgrep -a openfang` — cheap, honest, no side effects.
