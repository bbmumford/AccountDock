#!/bin/sh
# AccountDock Codex lifecycle hook for Codex builds supporting hooks.json.
# Walk past the short-lived hook runner to the persistent Codex app-server.
candidate_pid="$PPID"
agent_pid="$candidate_pid"
host="cli"
steps=0
while [ "$candidate_pid" -gt 1 ] 2>/dev/null && [ "$steps" -lt 12 ]; do
    command_line=$(/bin/ps -p "$candidate_pid" -o command= 2>/dev/null)
    case "$command_line" in
        *"/Visual Studio Code.app/"*|*"Code Helper"*) host="vscode" ;;
        *"/ChatGPT.app/"*) host="chatgpt" ;;
    esac
    case "$command_line" in
        *codex*"app-server"*) agent_pid="$candidate_pid" ;;
    esac
    next_pid=$(/bin/ps -p "$candidate_pid" -o ppid= 2>/dev/null | /usr/bin/tr -d ' ')
    [ -n "$next_pid" ] || break
    candidate_pid="$next_pid"
    steps=$((steps + 1))
done

ACCOUNTDOCK_PROVIDER="codex" \
ACCOUNTDOCK_AGENT_PID="$agent_pid" \
ACCOUNTDOCK_HOST="$host" \
exec /usr/bin/osascript -l JavaScript \
  "/Applications/AccountDock.app/Contents/Resources/accountdock-claude-hook.js"
