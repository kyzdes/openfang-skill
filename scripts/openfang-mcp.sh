#!/usr/bin/env bash
# openfang-mcp.sh — resolve the OpenFang binary on ANY machine and exec its stdio MCP server.
#
# Why a wrapper instead of a hardcoded path in .mcp.json:
#   - MCP servers are spawned by Claude Code WITHOUT a login shell, so `$PATH` is unreliable and
#     `~`/`$HOME` are not always expanded in the raw command string.
#   - The binary location differs per machine ($OPENFANG_HOME, a custom install, or just PATH).
# This resolves all of those, then `exec`s so the MCP server owns the process (clean lifecycle).
#
# Override order (first hit wins):
#   1. $OPENFANG_BIN               — explicit path to the binary
#   2. $OPENFANG_HOME/bin/openfang — honours a relocated home
#   3. ~/.openfang/bin/openfang    — the default install
#   4. openfang on $PATH
set -euo pipefail

BIN=""
if [ -n "${OPENFANG_BIN:-}" ] && [ -x "${OPENFANG_BIN}" ]; then
  BIN="${OPENFANG_BIN}"
elif [ -x "${OPENFANG_HOME:-$HOME/.openfang}/bin/openfang" ]; then
  BIN="${OPENFANG_HOME:-$HOME/.openfang}/bin/openfang"
elif [ -x "$HOME/.openfang/bin/openfang" ]; then
  BIN="$HOME/.openfang/bin/openfang"
elif command -v openfang >/dev/null 2>&1; then
  BIN="$(command -v openfang)"
fi

if [ -z "$BIN" ]; then
  echo "openfang-mcp: binary not found. Looked at \$OPENFANG_BIN, \$OPENFANG_HOME/bin/openfang," \
       "~/.openfang/bin/openfang, and PATH. Install OpenFang or set OPENFANG_BIN." >&2
  exit 127
fi

exec "$BIN" mcp "$@"
