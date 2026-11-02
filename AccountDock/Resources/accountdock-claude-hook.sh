#!/bin/sh
# AccountDock Claude lifecycle hook. The JavaScript companion performs all
# parsing and writes only recovery metadata; prompt and transcript content are
# never retained.
ACCOUNTDOCK_PROVIDER="claude" ACCOUNTDOCK_AGENT_PID="$PPID" exec /usr/bin/osascript -l JavaScript \
  "/Applications/AccountDock.app/Contents/Resources/accountdock-claude-hook.js"
