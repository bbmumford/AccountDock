# AccountDock release notes

## Unreleased

Smarter failover, sessions that survive the last account running out, and a
local request router for Claude Code.

### Serving sessions from several accounts

- Sessions are paced to each account's 5-hour window: new sessions go to the
  accounts with the most unused rate, a session keeps its account while its
  prompt cache lasts, and sessions leave an account only when it would reach
  its limit for longer than their cache lasts. A session refused at a limit
  that resets within five minutes, before its cache expires, waits for the
  reset on its account.
- Paused sessions resume a few at a time as capacity returns, each on an
  account where its forecast use fits before that account resets, the
  busiest first, instead of all at once on the first account that resets.
  A resumed session is paused again if its account nears its limit anyway.
- Every Claude request asks for the one-hour prompt cache, including
  subagent, workflow-agent and background requests and requests on extra
  usage, which Claude Code otherwise caches for five minutes, so one that
  comes after a longer gap keeps its cache. One-hour writes are
  priced at their real cost, and the settings show what the hour saved.
- An account at its limit whose reset comes before its working sessions'
  caches expire holds those sessions until the reset and continues them on
  it, instead of moving them to an account that writes their context again.
- When an account gives sessions up, those whose next turn comes soon go
  first, rather than one deep in a long turn that would move only at its end.
- Route targets offer only models with a 1M-token context window, and route
  sessions up to 90% of it by default instead of 200k tokens, so large
  sessions can keep running on Kimi K3 or K3.1 Pro.
- While requests go to a route target, sessions whose context is over its
  limit are paused, at their next tool call and their next prompt, instead
  of running into the exhausted accounts' limits; the rest keep running on
  the target.
- A session you resume on its own while its account has room is paused
  again when that account nears its limit, and a pause for a new limit holds
  sessions resumed during an earlier one. After an app restart, a resume
  had lasted past the pause it was given in, so the session ran into the
  limit.
- **Reinstall hooks** no longer makes every running session look as if it
  started before the pause hook, which had the pause warn that it could not
  hold them.
- Turning routing off while requests go to the target says so, instead of
  reporting that the target can no longer serve.
- Session rates and forecasts are kept across restarts, and a paused
  session keeps its history for as long as the pause lasts. A session paused
  for more than six hours had been forecast from the other sessions instead,
  and one resumed and paused again from nothing.
- Each account's token cost is learned on its own, so plans of different
  sizes are forecast correctly.
- Pacing counts the weekly allowance as well as the 5-hour window: an
  account about to run out for the week gives sessions up, and one whose week
  resets soon takes more new sessions before its allowance is lost.
- With sessions served from several accounts, sessions pause only once no
  included account has room left, instead of whenever the active account and
  no switch destination did, which left the last of the other accounts'
  windows unused.
- Extra usage is used when every allowance is spent. The account on extra
  usage had been chosen, but sessions were paused for its limit anyway; with
  several accounts serving sessions, it now serves all of them.
- AccountDock's hooks in Kimi Code's config are recognised by their command
  as well as their header comment. A program that rewrote the file with a
  TOML serializer dropped the comments, and AccountDock then added its hooks
  again beside the unmarked copies each time.

### When every account is exhausted

- Claude Code requests can be served by a route target (Kimi, with a choice of
  model) through AccountDock's local router, and return to Claude as soon as an
  account has capacity. Sessions stay open throughout.
- Routing to a target only starts when the target would carry the current
  demand for a set time, keeps a share of its window for its own sessions, and
  leaves sessions above a context size on Claude. A target counts every routed
  token, so large sessions could otherwise use a 5-hour window in minutes.
- Claude Code's server-side conversations and deferred tools are adapted for
  targets without them, which had made routed requests fail with "tool_call_id
  is not found" and "Invalid request".
- Routed requests count as the target's usage, with its model and price, in
  the Usage tab instead of an unpriced Claude model.
- Pausing no longer stops processes with `SIGSTOP`, which detached terminals.
  A pause gate hook holds only the sessions that were mid-turn when the limit
  hit, with the terminal attached and a message showing why. Paused sessions
  are let through one step at a time while an account still has room.
- Kimi Code's base URL is never pointed at AccountDock's router. Kimi Code
  signs its requests only for its own hosts, so new Kimi Code sessions
  failed with "provider managed:kimi-code has no credential configured"; a
  base URL left pointed there is written back.
- Kimi Code sessions can be paused too. The Kimi Code gate is installed
  within Kimi Code's 600-second hook limit, so Kimi Code no longer ignores
  every hook in its config, and a resumed Kimi Code turn is told to check the
  background work it started.
- Choosing an account that failover excludes no longer resumes paused
  sessions.
- A pause holds every session at its next tool call, including subagents and
  workflow agents and sessions not seen mid-turn when it began. Before, a
  session left the pause at its next prompt, which a subagent reporting back
  is, and its agents then ran on into the limit.
- One paused session can be resumed while the others stay paused: press
  ⌃⌥⌘R with its terminal in front (its title shows the shortcut), or pick it
  from **Resume one** in the pause banner. When the front window holds more
  than one paused session, the shortcut shows a menu to choose from.
- **Pause sessions now** in the failover settings pauses sessions on demand, so
  work can move onto accounts at their limits without a request failing first.
- While sessions are paused, a turn that starts waits before its first request
  instead of being refused at the limit, and continues when capacity returns.
- Claude accounts with extra usage can keep serving past their plan, up to a
  monthly spending limit.
- Banners in the usage view and badges in the menu bar show routed and paused
  sessions, with **Return now** and **Resume now**.

### Planning

- Under each provider, the usage view estimates at the current pace when the
  active account reaches its limit and when sessions would be paused.
- An account held just short of its limit now waits for its own reset. Before,
  AccountDock could prepare an account whose weekly limit was spent for days
  and switch between the two every minute.
- A reset that is not today is shown with its day.
- Sessions started before the pause hook was installed are named in the usage
  view, since a pause cannot hold them until they are restarted.

- Work moves while there is still room for the requests already under way,
  and an account at its limit moves only to an account with room for at least
  ten minutes of the current use.
- An account the provider just refused is never chosen until its reset.
- Destinations must have room on both windows for the expected use over the
  minimum dwell, plus the cost of moving the sessions' context.
- Decisions look 30 seconds ahead and use each account's usage rate plus its
  variability.
- Model-scoped weekly limits are read and planned for.
- AccountDock learns what a request costs and your usage by hour of the week.
  With a day of history, balancing simulates the coming week and the usage view
  shows the week's outlook.
- Optionally serve each Claude Code session from its own account, so several
  5-hour windows are used at once.

### Usage readings

- Accounts are read oldest first within each provider's request budget, so an
  account at the end of the list is no longer deferred for hours.
- Window warming works for Kimi accounts, and a failed warm-up says why.

### Router

- Runs whenever Claude failover is on: running sessions move to the newly
  active account at their next turn, and a request refused at a plan limit is
  sent again on the next account instead of failing.
- Retries requests whose connection to Anthropic drops before any reply, on a
  fresh connection, and spreads sessions over several connections.
- Recognises running sessions after AccountDock restarts.
- When the route target reaches its own limit, sessions go back to Claude at
  once instead of receiving the target's error; with every option out, a
  session gets Claude's own limit reply, so Claude Code waits for the reset and
  continues by itself.
- Stops the upstream reply when a session interrupts a turn, so an abandoned
  reply no longer uses up the account, and closes connections a session has
  hung up; these had kept the router busy at several cores.

- Installed, updated and removed automatically; runs only while a setting needs
  it.
- Listens on localhost only, refuses web pages, and serves your accounts only to
  clients that already hold one of your credentials.
- Credentials come from the Keychain through an authenticated local connection
  and stay in memory; no token files.
- Learns usage from every response it forwards, reducing usage-endpoint
  requests.

### Hooks and settings

- AccountDock checks its hooks on launch and offers to install any that are
  missing; Settings → General → Agent hooks shows and reinstalls them.
- Failover settings reorganised around what happens when every account is
  exhausted; refresh choices simplified to 1, 5 or 10 minutes.
- Every provider's settings, hooks, menu-bar modules, usage cards and
  today's activity come from one capability registry, so the pause controls,
  window warming, switch method, live usage and routing settings appear for
  each provider that supports them, and a provider added later gets them too.
- Account cards show the running sessions of every provider, from the
  session hooks each CLI already runs, not only the sessions the router
  served. Today's sessions and tokens are shown per provider in the cost view.
- When paused sessions continue, the message names where they go on: the
  route target and model, or the account now active.
- Window warming works for Kimi, and its setting is shown only for providers
  that can warm a window.
- Providers are shown or hidden from one list in Settings → General; existing
  choices carry over.

### Reliability

- A macOS Keychain prompt can no longer freeze AccountDock. Saved accounts are
  read in the background and kept in memory, so failover, pauses and resumes
  keep running while a prompt waits, and the menu says what it is waiting for.
- An account whose saved sign-in Claude rejects raises a macOS notification
  asking you to re-authenticate it; a network failure no longer marks an
  account as expired.

- An incomplete Claude credential is never saved over a good backup, each
  backup keeps the previous token, and restoring the active account no longer
  backs up the credential it replaces.
- The live Claude credential is written through standard input instead of the
  command line, and read back to verify.
- Idle Claude accounts' tokens are renewed before they expire.
- Profile requests count against the usage-request allowance.
- Account cards count only sessions with a transcript, not one-shot background
  requests.

### Documentation

- README, architecture and build guide rewritten; screenshots rendered from
  sample data with `Tools/render_screenshots.sh`.

## 1.2.0

- Kimi Code accounts: capture or log in, isolated credentials, usage, costs,
  failover and menu-bar modules.
- Provider capabilities declared once and shared by accounts, usage, failover
  and settings.
- Quota-aware failover with usage-request budgets and projection while a
  provider throttles.
- Agent suspension when every account is exhausted.
- Compact dual-window quota rings, provider-aware activity summaries, Codex
  patch line counts and metric-source tooltips.

## 1.1.0

Provider-aware account ordering, safer failover, and live Codex session recovery.

- Separate, reorderable Claude and Codex account groups shared by Accounts and
  Usage, with provider-scoped account ordering.
- Per-account failover inclusion controls that remain independent from display
  order.
- Adaptive Claude and Codex failover using last-known quota and reset data when
  providers temporarily throttle or reject a refresh.
- Correct Codex failover selection when cached candidate quota is still known.
- Codex safe switching and automatic failover recovery for long-lived
  app-servers, with CLI session resume and host-managed IDE reconnection.
- Codex Free-plan 30-day quota detection, display, persistence, and failover
  threshold support.
- Passed-reset reconciliation that prevents stale 100% usage from remaining
  indefinitely when credentials cannot be refreshed.
- Codex failover settings no longer expose a nonexistent session window.
- Updated lifecycle hooks, documentation, and regression coverage.
