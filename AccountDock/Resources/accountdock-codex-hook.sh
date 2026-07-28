#!/bin/sh
# AccountDock Codex lifecycle hook for Codex builds supporting hooks.json.
ACCOUNTDOCK_PROVIDER="codex" ACCOUNTDOCK_AGENT_PID="$PPID" exec /usr/bin/osascript -l JavaScript \
  "/Applications/AccountDock.app/Contents/Resources/accountdock-claude-hook.js"
