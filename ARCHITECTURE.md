# AccountDock Architecture

AccountDock is a native macOS menu-bar app (Swift 6, SwiftUI, macOS 14+) that
manages several accounts for each of three AI coding CLIs: Claude Code, Codex
and Kimi Code. It switches the account each CLI uses, reads every account's
quota, plans which account should carry the work, and can keep Claude Code
sessions running through a local request router when every account is spent.

This document describes how the parts fit together and why they are shaped the
way they are. User-facing behaviour is in the [README](README.md); building and
releasing are in [BUILD_GUIDE.md](BUILD_GUIDE.md).

## Components

```
                         ┌──────────────────────────────────────────────┐
                         │ AccountDock.app  (menu bar, LSUIElement)      │
                         │                                              │
  provider usage APIs ◄──┤  AppState (@MainActor)                        │
  claude / codex / kimi  │   ├─ accounts, usage, costs, activity         │
  CLIs and their files ◄─┤   ├─ failover cycle  ── FailoverPlanner       │
                         │   │                     QuotaSimulator         │
  macOS Keychain ◄───────┤   ├─ learning: QuotaTrend, TurnCostModel,     │
                         │   │            DemandForecast                 │
                         │   ├─ pause gate  ── AgentPauseGate            │
                         │   └─ router control ── RequestRouterController│
                         │  SwiftUI views, status item, Settings window   │
                         └───────┬──────────────────────┬───────────────┘
                                 │ state + credentials   │ installs hooks
                                 │ (localhost, keyed)    ▼
   Claude Code ──HTTP──► AccountDockRouter        ~/.claude/settings.json
   (ANTHROPIC_BASE_URL)  launchd agent,           ~/.codex/hooks.json
                         127.0.0.1:47321          ~/.kimi-code/config.toml
                            │        │
                            ▼        ▼
                    api.anthropic.com   route target (e.g. Kimi)
```

| Part | Where | Role |
| --- | --- | --- |
| App | `AccountDock/` | Menu-bar UI, account management, usage and cost readers, failover, hooks, router control |
| Router | `AccountDockRouter/` | Local HTTP proxy for Claude Code; serves requests from a pool of Claude accounts or a route target |
| Router core | `AccountDockRouter/Core/` | Pure routing logic and shared types, compiled into both the router and the app |
| Widget | `AccountDockWidget/` | WidgetKit extension that renders `Shared/WidgetData.swift`: labels, icons and windows the app's `WidgetProjection` writes from the providers' capabilities |
| Hook scripts | `AccountDock/Resources/`, generated at install | Session lifecycle records, the pause gate and Claude Code status-line telemetry |
| Tests | `AccountDockTests/` | Unit tests for planning, routing, parsing, credentials and hooks |

`project.yml` is the single source of project configuration. The router is a
command-line tool target embedded in the app bundle under `Contents/MacOS`, so
one installed app always carries a matching router build.

## Providers

`AccountDock/Models/ProviderCapabilities.swift` declares each provider once.
Shared account, usage, failover, routing, hook and settings code reads this
registry instead of branching on provider names, so a new provider gets every
feature its capabilities declare, and its settings appear with it:

| Capability | Drives |
| --- | --- |
| Quota windows, labels, `longWindowReportsLength` | Usage cards, menu-bar modules (one set of metrics per provider), the widget, failover thresholds |
| `requiresPaidPlanForWorkloads`, `unavailableLabel` | Whether a plan can carry work |
| `usageRequestBudget` | The provider's `UsageRequestBudget` |
| `supportsWindowWarming` | Window warming and its setting |
| `supportsSelectableSwitchMode`, `switchReachesRunningSessions` | The switch method setting; whether a switch waits for a reset and restarts paused sessions to reach them |
| `credentialSharedAcrossSessions`, `credentialStore` | Whether a switched-away account can still be consumed; the Keychain access notice |
| `pauseGate`, `lifecycleHooks`, `cliExecutableName` | Pausing sessions, session records and finding the CLI's processes |
| `liveUsageFeed` | The status-line usage feed and its setting |
| `requestRouter` | Which provider's CLI the router serves (`AIProviderType.routedProvider`) and the routing settings |
| `routeTarget` | The service the provider offers as a route target |
| `supportsExtraUsage` | The extra-usage setting and card row |
| `activityMetrics`, `pricingPrefixes`, `pricingAliases`, `shortBadge` | Today's activity, cost and their labels |
| `storageKey`, `longWindowStorageName`, short labels | Stored menu-bar module names (`claudeSession`, `kimiMonthlyReset`) |

Provider-specific work stays in one service per provider, reached through
small adapters, each one function with a case per provider:

- `readUsage` reads an account's usage and plan; `applyUsageRead` records
  the outcome the same way for every provider;
- `QuotaWindowProbe` reads an account's live windows and starts an unstarted
  one for window warming;
- `accessCredential` and `currentAccessToken` supply the tokens the router
  sends upstream and recognises;
- `credentialIsUsable`, `prepareSwitchReachingSessions` and `activate` make an
  account active with the provider's switch method;
- `loginNewAccount`, `captureCurrentAccount`, `removeAccount` and
  `reauthenticateAccount` manage accounts;
- `CostParser.costHistory(for:)` aggregates a provider's local usage records;
- `PassiveUsageObservation.Source` names the provider a passive reading
  belongs to and how it names its account.

Some data is the same for every provider by construction:

- **Sessions.** Every provider's lifecycle hooks write the same record
  (`Sessions/<pause gate key>-<session>.json`). `AgentSessions` reads them
  for all providers: live sessions (process alive, not ended), the sessions
  mid-turn that a pause lists, and process-to-session matching for restarts.
  `AppState.refreshSessions` assigns each live session to the account the
  router last served it from, or else its provider's active account; the
  account cards show these counts.
- **Cost and activity.** `CostParser.ProviderCostHistory` holds each
  provider's daily cost and today's turns, models, lines, tokens, sessions and
  active time. Claude Code's is built from its per-request cost summary; the
  others from their per-day, per-model aggregates. `TodaySummary` sums today's
  figures over the providers the user has not hidden, each metric over the
  providers whose `activityMetrics` report it; the usage dashboard, the cost
  tab, the menu bar and the widget all read it and write costs and tokens with
  `UsageFormat`.

| Provider | Service | Credentials | Windows |
| --- | --- | --- | --- |
| Claude Code | `ClaudeService` | Keychain item `Claude Code-credentials` plus `oauthAccount` in `~/.claude.json` | 5-hour session, 7-day weekly, model-scoped weekly limits |
| Codex | `CodexService` | One managed `CODEX_HOME` per account, promoted atomically to `~/.codex/auth.json` | 5-hour when the plan reports it, 7-day (30-day on Free) |
| Kimi Code | `KimiService` | One isolated credential copy per account, promoted atomically into Kimi Code's slot | 5-hour session, the stricter of monthly total and monthly coding |

Failover never moves work from one provider's accounts to another's. The only
cross-provider path is the request router's route target, described below.

## Credential storage

### Claude

Claude Code owns one live Keychain item and reads the signed-in identity from
`~/.claude.json`:

```
macOS Keychain
  Claude Code-credentials / <OS user>     live OAuth token JSON (Claude Code owns it)
  app.accountdock.backups / all-accounts  every account's backup, one JSON dictionary:
                                          { "<account UUID>": { token, oauthAccount, previousToken } }
~/.claude.json
  oauthAccount                            identity of the live token (email, account UUID, org)
```

- **Live slot.** AccountDock reads and writes `Claude Code-credentials` through
  `/usr/bin/security`, the same tool Claude Code uses, so the item's access
  list is shared rather than re-prompted. Writes go through `security -i` on
  standard input, which keeps the token out of every process's argument list;
  only a credential too long for one interactive line (about 4 KB) falls back
  to an argument. Every write is read back and compared.
- **Backups.** All account backups live in one Keychain item owned by
  AccountDock (`app.accountdock.backups`), accessed through the Security
  framework. Backups from the upstream app (`me.xueshi.ccswitcher.backups`) and
  an older `backups.json` file are imported once.
- **Never on the caller's thread.** macOS asks again for access to
  `app.accountdock.backups` whenever the app's code signature changes, as it
  does with every ad-hoc build, and a Keychain call waits until the prompt is
  answered. The backups are therefore read once on a background queue and kept
  in memory, and changes are written back on that queue. Until the first read
  completes, AccountDock refuses to change the backups (a write then would
  replace every saved account), treats them as unknown rather than missing, and
  shows that it is waiting for Keychain access; the failover cycle, pauses and
  the active account keep working.
- **Completeness.** A token JSON without its refresh token, expiry or scopes is
  refused as a backup. Each backup keeps the previous complete token, and a
  restore whose stored token is incomplete uses that earlier copy.

The token JSON carries no identity. AccountDock therefore only backs up the
live token under an account after `oauthAccount` in `~/.claude.json` names that
same account.

### Token JSON format

The token stored in keychain is a single JSON object (captured from real keychain entry):

```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-************************************************************-hZQ2uQAA",
    "refreshToken": "sk-ant-ort01-************************************************************-MO7X_wAA",
    "expiresAt": 1774128766541,
    "scopes": [
      "user:file_upload",
      "user:inference",
      "user:mcp_servers",
      "user:profile",
      "user:sessions:claude_code"
    ],
    "subscriptionType": "pro",
    "rateLimitTier": "default_claude_ai"
  }
}
```

**Key observations:**
- `accessToken` prefix: `sk-ant-oat01-` (OAuth Access Token)
- `refreshToken` prefix: `sk-ant-ort01-` (OAuth Refresh Token)
- `expiresAt` is a Unix timestamp in **milliseconds** (not seconds)
- `scopes` is an **array of strings** (not a single string)
- The token JSON does **NOT** contain email or account identity — the only way to determine which account a token belongs to is by calling `claude auth status` while that token is active
- This lack of embedded identity is why AccountDock checks `oauthAccount` before it backs up a live token.

### Codex and Kimi

Each Codex account has its own managed home directory. Switching copies that
home's `auth.json` into `~/.codex/auth.json` with an atomic rename, so a running
Codex process never reads a half-written file. Each Kimi account has an
isolated copy of Kimi Code's credential file. Kimi rotates its refresh token on
every renewal, so a renewed token is written back to the managed copy before it
is used.

## Claude account switching

`ClaudeService.switchAccount(from:to:)` is transactional: it snapshots the live
token and identity first and restores them if any later step fails.

1. **Back up the source.** If `oauthAccount` names the source account, the live
   token and identity are saved as its backup. When the source and target are
   the same account (restoring the active profile), nothing is backed up: the
   live credential is the one being replaced and must not overwrite the copy
   being restored.
2. **Read the target backup.** An incomplete stored token falls back to the
   backup's previous token; with neither, the switch stops.
3. **Write.** The target token goes into `Claude Code-credentials` and the
   target identity into `~/.claude.json`.
4. **Verify.** `claude auth status` must report the target's email and be
   logged in. Anything else rolls back to the snapshot.

Running Claude Code processes keep the token they started with until they
refresh it, so a switch moves new requests, not requests already in flight.
Automatic failover never terminates or restarts Claude Code sessions.

When Claude rejects an idle account's saved sign-in even after renewing it, the
account is left out of failover and a macOS notification asks the user to
re-authenticate it, since its allowance is lost until they do. A network or
server failure during renewal does not count as a rejection.

### Adding and re-authenticating accounts

Adding an account first captures the active account's credentials, then runs
`claude auth login`. The identity in `~/.claude.json` names the new login; if
it matches an existing account, that account's backup is refreshed instead of
creating a duplicate. Re-authenticating follows the same path for one account.
Idle accounts' tokens are renewed shortly before they expire, without touching
the live slot.

### `claude auth login`

When `claude auth login` runs, it performs a standard **OAuth 2.0 Authorization Code + PKCE** flow:

```
Claude CLI                    Browser                   claude.ai Server
    │                            │                            │
    │  1. Start local HTTP       │                            │
    │     server (random port)   │                            │
    │                            │                            │
    │  2. Build OAuth URL:       │                            │
    │     https://claude.ai/oauth/authorize                   │
    │     ?redirect_uri=http://localhost:<port>/oauth/callback │
    │     &code_challenge=<PKCE SHA256>                       │
    │     &code_challenge_method=S256                         │
    │                            │                            │
    │  3. open(URL) ────────────►│                            │
    │     (system default browser)│                           │
    │                            │  4. User logs in           │
    │                            ├───────────────────────────►│
    │                            │                            │
    │                            │  5. Server returns          │
    │                            │     auth code via redirect  │
    │                            │◄───────────────────────────┤
    │                            │                            │
    │  6. Browser redirects to:  │                            │
    │     localhost:<port>/      │                            │
    │     oauth/callback?code=xx │                            │
    │◄───────────────────────────┤                            │
    │                            │                            │
    │  7. Exchange code + PKCE   │                            │
    │     verifier for tokens    │                            │
    │────────────────────────────────────────────────────────►│
    │◄────────────────────────────────────────────────────────┤
    │     {accessToken, refreshToken, expiresAt, ...}         │
    │                            │                            │
    │  8. Store in macOS Keychain│                            │
    │     service: "Claude Code-credentials"                  │
    │     account: "<OS username>"                            │
    │     password: JSON with OAuth tokens                    │
    │                            │                            │
    │  9. Close local server     │                            │
    │     Exit process (code 0)  │                            │
```

**Key points:**
- The CLI starts a **local HTTP server on a random port** as the OAuth redirect target
- Uses **PKCE** (Proof Key for Code Exchange) to prevent authorization code interception
- The process **blocks until the browser callback arrives** — `Process.waitUntilExit()` waits for login completion
- Token is written to Keychain **before** the process exits, so reading it immediately after is safe
- The login **always replaces** the current Claude Code session — this is Claude CLI's own behavior

## Usage readings

AccountDock prefers quota data the agents already record:

- the rate limits Claude Code passes to its status-line command with every
  response, through an optional wrapper that keeps the configured status line;
- the usage Claude Code caches in `~/.claude.json`;
- `token_count.rate_limits` in Codex rollout files;
- the `anthropic-ratelimit-unified-*` headers the router sees on every response
  it forwards, keyed by credential fingerprint.

Provider usage endpoints are a scarce, rate-limited resource. Each provider has
one `UsageRequestBudget` (a token bucket), so the active account can always be
read when a decision depends on it, while idle accounts are read sparsely.
Accounts are read active first, then oldest reading first, so the account at
the end of the list is not the one left unread whenever the budget runs short.
Throttling backs off for every account of that provider, from one minute up to
fifteen. While a provider throttles, `QuotaTrend` projects the active account's
usage forward from its learned burn rate so failover still acts on time.

Claude's response includes every limit it applies, including weekly limits
scoped to one model (`limits[]` with `kind: weekly_scoped`) and the share of the
weekly allowance each may use. The planner uses the model-scoped window that
applies to the model the sessions are using, read from the status line.

## Failover planning

`FailoverPlanner` is a pure function from accounts, readings and settings to a
plan: stay, switch, verify (read some accounts, then plan again), wait for a
reset, or no capacity. `AppState+Failover.swift` runs it on a monitoring cycle
and carries out the plan. Only one evaluation runs at a time, because a second
one would plan from a half-switched state.

### Tiers

Every account is placed in a tier, as it will be 30 seconds from now (one
monitoring cycle plus the switch itself):

| Tier | Meaning |
| --- | --- |
| below trigger | every window is below its threshold, with room for the minimum dwell |
| usable | above a threshold but able to serve |
| exhausted | a window is at the provider's limit |
| ineligible | no trustworthy reading, unusable credentials or no workload entitlement |

### Headroom

For an account with session use `s` and weekly use `w` (percent), the work it
can still serve now, in session percent, is

```
H = min(100 − s, (100 − w) · k)
```

where `k` is how many session percent one weekly percent buys on that plan. `k`
is learned from paired readings and shared across a provider's accounts on the
same plan (default 8).

A destination must stay below its thresholds for the minimum dwell. Its margin
is the expected burn over the dwell, plus the session percent the move itself
costs (the moved sessions re-read their context into the new account's cache,
estimated by `TurnCostModel.switchCost`). Burn rates are taken at their mean
plus one standard deviation, so a noisy account is treated as faster than its
average.

### Rules, in order

The active account counts as at its limit once its headroom on the upper
estimate is less than the **in-flight reserve**: one expected request (from
`TurnCostModel`) for every session active in the last three minutes, capped at
10%. Requests already under way still spend that much after a switch, so work
moves while they still fit.

1. The active account crosses a threshold (or will within the lookahead):
   switch to the first account below its thresholds, in the user's order.
2. No such account: keep serving up to the provider's 100% limit. Moving to an
   account that is merely less full than its threshold adds no capacity and
   causes switch loops.
3. At its limit: move to the usable account with the most headroom, if that
   headroom covers the in-flight reserve, the switch cost and ten minutes of the
   current burn. A smaller sliver would be spent before the move paid off.
4. Every allowance spent: serve on extra usage if the user allowed it and the
   monthly spending limit has room.
5. Otherwise: wait for the account whose limiting windows all reset first. A
   session-limited account is not ready while its weekly window is still spent.
   The active account is judged at the margin it is held at in step 3 (the
   in-flight reserve), so an account held at 98% waits for its own reset
   instead of an account whose weekly window resets days later being
   prepared, which had switched between the two every minute.

A destination whose reading may be out of date is read again before the switch
(`verify`) rather than skipped, so the user's order is honoured with current
data. Readings expire after 10 minutes for an account that sessions may be
consuming unseen, after 15 minutes for an idle account when a read can be
afforded, and after 6 hours for an idle account when it cannot, since only its
own resets change it.

### Balancing

Optional intelligent balancing spends allowances in order of their latest
feasible start: the latest moment continuous use must begin for an account's
remaining weekly allowance to be used before it resets, given that the 5-hour
cap limits how fast it can drain:

```
latestStart = R_w − (100 − w) / ((100 / k) / 5 h)
```

where `R_w` is the weekly reset. An allowance that resets sooner, or that the
5-hour cap could no longer drain in time, is used first. A minimum deadline
advantage and dwell prevent oscillation.

Whether an account has a session window is read from each reading, account by
account, because a plan can drop it while others keep it (Claude's Ultra plan
for verified accounts; Max keeps it). A reading with the long window and no
session window means the account has none: `merged(withNewer:clearingSession:)`
drops a stored window, `FailoverPlanner`, `QuotaSimulator` and `SessionPacer`
limit the account by its long window alone, and no warm-up probe runs for it.
`QuotaTrend` then holds its long-window baseline until it has risen two points
or for 30 minutes, since a whole-percent step in a short interval is rounding.

Once AccountDock has learned at least a day of hourly demand
(`DemandForecast`, 168 hour-of-week buckets), balancing instead compares
strategies with `QuotaSimulator`: it plays the forecast demand over the coming
week in 15-minute steps, following each account's session and weekly resets,
and picks the strategy that serves the most work and lets the least allowance
expire unused. The usage view shows the resulting one-line outlook for the week.

The same simulator, with demand held at the active account's current burn
instead of the forecast, gives the pace line under each provider heading
(`AppState.paceOutlook`): when the active account reaches a limit, and when
every included account is used up, which is when sessions are paused. It is
shown whenever the active account is in use and no pause is under way, for any
provider, with or without a forecast.

### Learning

| Model | Learns | Used for |
| --- | --- | --- |
| `QuotaTrend` | burn rate per window and its variance, per account | projection while throttled, trigger timing, uncertainty |
| `TurnCostModel` | session percent per million weighted tokens, from router token counts and the readings that follow | expected request cost, switch cost |
| `DemandForecast` | weekly percent consumed per hour of the week | the simulator's demand |

Token weights follow relative price: context read from cache 0.1, cache writes
1.25, output 5. Learning is stored in `UserDefaults` under
`app.accountdock.learning.v1`.

## Pausing sessions

When every account is exhausted and no route target is configured, AccountDock
can pause sessions, so no request fails against a spent account. The user can
also pause them on demand from Settings → Failover, for example before moving
work off an account that failover excludes onto accounts at their limits.

Pausing is cooperative. A hook script (`accountdock-gate.sh`) runs after every
tool call (before every tool call for Kimi Code, whose post-tool hook does not
wait) and waits while the provider's pause file exists under
`~/Library/Application Support/AccountDock/Pause/`. The terminal stays attached
and the session shows a status message and terminal title while it waits.

- While the pause file sets `holdsNewTurns`, as every pause does, every session
  waits at its next tool call: also sessions not seen mid-turn when the pause
  began, and the subagents and workflow agents inside a session, which share
  its session ID. The sessions mid-turn at the start are listed for display
  and for the order steps are released in; a listed session leaves the list
  only when it ends.
- The same script runs on `UserPromptSubmit`, so any turn that starts waits
  there before its first request, including a subagent reporting back to its
  session or a scheduled agent waking up. The pause file stays until capacity
  returns.
- A pause the user started is marked `manual`; it releases no steps within
  headroom.
- A hook may wait only as long as its CLI allows, and Kimi Code allows 600
  seconds; refusing the step at that limit costs a model request each time,
  and once the window is spent the turn fails. A provider that declares
  `requestHold` therefore has its model requests sent through the router
  while it pauses agents and the router runs (`ProviderRequestHold`): its
  base URL (for Kimi Code, `base_url` in `[providers."managed:kimi-code"]`)
  points at `/__provider/<key>`, the previous value is kept in
  `Router/passthrough.json` as the upstream, and it is written back when
  pausing is turned off or the router is no longer wanted. A hold with
  `bridgedProtocol` (Codex) follows its own setting instead and holds no
  request (`holdsPausedRequests: false`). A provider whose
  CLI stops signing its requests at another base URL declares
  `keepsCredentialAtRouter: false` and is never pointed there; only a base
  URL found pointed there is written back. Kimi Code is one: it attaches its
  sign-in to the managed provider only while `base_url` names one of its own
  hosts, so its sessions keep the gate's refusal at the 600-second limit.
  `ProviderPassthrough` forwards each request unchanged with the client's own
  credential, and holds it while the pause holds the session by the gate's
  own rule (the pause file, `.allow` steps, `.resumed` sessions; the session
  is the request's `prompt_cache_key`). A held streamed request is answered
  with its 200 head at once and kept open with event-stream comments, so the
  CLI neither times out nor retries, then receives the provider's reply when
  the pause ends. With the hold active, the gate lets a step go on at its
  limit instead of refusing it.
- A CLI reads its hooks when it starts, so a session started before the gate
  was installed in a form the CLI accepts runs without it and no pause holds
  it. `AgentPauseGate` records when each provider's gate was written
  (`Pause/<key>.installed`; a repair, or **Reinstall hooks**, that keeps the
  events and timeout keeps the time, because running sessions already call
  the same script), and
  `AppState.sessionsWithoutGate` compares each live session's process start
  time with it. The usage view names such sessions and asks for a restart;
  a pause records how many it cannot hold.
- One session can be resumed on its own while the others stay held: a
  `<key>-<session>.resumed` file makes the gate stop holding that session,
  its subagents (which share its session ID) and its later turns until the
  pause ends; a new pause holds it again. A pause started for a new limit
  removes the markers of the sessions it lists
  (`AgentPauseGate.clearResumed`), since a pause file left from before,
  as after an app restart, would otherwise keep them. A session resumed onto
  an account with room (`AppState.userResumes`) is held again at its next
  tool call once the account serving it is at its limit or within
  `suspensionLead` of it; one resumed onto an account already at its limit
  runs for the rest of the pause. The pause banner lists the waiting
  sessions, and the system-wide shortcut ⌃⌥⌘R (`SessionResumeShortcut`, a
  Carbon hot key, so no Accessibility permission) resumes the one in the
  front window. The gate writes its process ID into its `.waiting` marker;
  the waiting session whose gate descends from the frontmost app is the one
  resumed. When the frontmost app shows several, or none, a menu at the
  pointer lists the candidates. The waiting session's terminal title names
  the shortcut.
- No pause ends because the user chose an account that failover excludes:
  sessions wait for **Resume now** or for capacity on an account in the
  failover order (the account active when the pause began only after a window
  reset).
- Every way out of a pause goes through `AppState.endPause`: capacity returned,
  a route target took the requests, or the user resumed; a route target that
  cannot take some sessions narrows the pause to them instead. The gate tells each
  resumed Claude Code agent to check its background work in all three cases.
- While the account still has some room, one step at a time is released through
  an `.allow` file, within the remaining headroom.
- The pause ends when a reading confirms capacity, or when the user chooses
  **Resume now**.
- Every way a pause ends goes through `AppState.endPause`, which records
  where the sessions continue (the route target and model, or the account
  now active). The gate shows it to the user and the agent as each session
  goes on.
- When a session continues, the hook replies in the form its CLI reads
  (`PauseGateSupport.reply`): Claude Code shows the user how long it waited
  and gives the agent `additionalContext`; Kimi Code adds `message` to a new
  turn's context. The agent is told that requests its subagents, workflows,
  teammates or background commands made during the pause may have failed, so
  it checks each one it started and resumes those that stopped. Nothing else
  restarts a background agent whose request failed at the limit.
- A hook waits at most 24 hours, within the CLI's hook timeout. A CLI with a
  shorter limit (`PauseGateSupport.maximumHookTimeout`; Kimi Code accepts at
  most 600 seconds and ignores its whole `[[hooks]]` section when one entry
  asks for more) is given a timeout within it. When that shorter wait ends
  with the pause still on, the hook refuses the step (exit status 2 with a
  reason), so the agent asks for the tool call again and waits again rather
  than running on into the limit; a refused new turn tells the user to send
  the message again. `AgentPauseGate.synchronize` rewrites any installed gate
  whose command or timeout differs from the current one.

Stopping a process with `SIGSTOP` is used only for agents that cannot run the
hook, and never for a job in an interactive shell: a shell treats a stopped
foreground job as suspended, detaches it from the terminal and returns its
prompt.

## Request router

`AccountDockRouter` is a small HTTP proxy (Network.framework) that runs as the
launchd agent `app.accountdock.router` on `127.0.0.1:47321`. Claude Code reaches
it through `ANTHROPIC_BASE_URL` in the `env` block of `~/.claude/settings.json`,
so it applies to Claude Code sessions started after it was enabled. It runs
while Claude failover, a route target or distributed sessions are on, and does
three things:

- **Move running sessions with failover.** A Claude Code process keeps the
  access token it has read until it refreshes it, so a Keychain switch reaches
  running sessions late, and their requests meanwhile hit the old account's
  limit. The router replaces each request's credential with the active
  account's, so every session moves at its next turn (a turn in progress
  finishes on its account). The other accounts with room follow in failover
  order, and a request one refuses at its plan limit is sent again on the next.
- **Serve sessions from several accounts.** Each session is assigned an account
  from a weighted pool and keeps it while that account has room, so several
  accounts' 5-hour windows are used at once.
- **Pace sessions to each account's window** (on by default with the above).
  See [Session pacing](#session-pacing).
- **Route to a target when every account is exhausted.** Requests go to the
  route target (Kimi's Anthropic-compatible endpoint today) and return to Claude
  when an account has capacity. The router keeps a request whose context is
  over the target's cap (`routeMaxContextTokens`, else 90% of the chosen
  model's window, `RouteTarget.defaultMaxContextTokens(model:)`, since the
  router counts Claude tokens and the target its own) on the exhausted
  accounts, so every live session with a larger context is paused instead
  (`AppState.holdSessionsTooLargeForRoute`): `AgentPauseGate.narrow` lists
  only those, with `holdsListedNewTurns` so each also waits at its next
  prompt, and lets every other waiting session continue on the target. When
  an account can serve again the route ends and the held sessions resume as
  capacity allows. Only models of at least `RouteTarget.minimumModelContext`
  (1M tokens) are offered (`routableModels`). A target is offered for a
  provider whose CLI the router speaks, and for one whose requests it bridges
  (see [Serving a Responses CLI from a route target](#serving-a-responses-cli-from-a-route-target)).

### Session pacing

With **Pace sessions to each account's 5-hour window**, `SessionPacer` decides
the pool weights and which sessions move, each time the pool is rebuilt
(`AppState.buildPool`, every quota cycle):

- Each session's rate is its weighted tokens (`TurnCostModel.weighted`)
  decaying with a 20-minute time constant (`SessionRates`), converted to
  window percent per hour with the learned `TurnCostModel.ratio`. An
  account's rate is the larger of its sessions' total and the rate its own
  readings show, which includes use the router does not see. The readings'
  rate follows a move only over several readings, so the rate of sessions
  that just left an account (`SessionRates.departed`) is taken off it until
  then; otherwise an account that gave sessions up would keep looking busy
  and give up more than it needs to.
- An account's outlook compares that rate with the rest of its window (to
  99%, leaving in-flight turns room) over the time to its reset, or over a
  full 5 hours when no window is running, and with what is left of its
  weekly allowance (in 5-hour percent, by the plan's measured ratio) over the
  time to the weekly reset. The limit reached first decides, so an account
  about to run out for the week gives sessions up, and one whose week resets
  soon takes more new sessions before its allowance is lost.
- An account that would reach its limit and then wait there longer than its
  sessions' prompt cache lasts (the longest `cache_control` lifetime they
  sent, an hour when unknown) gives sessions up: those relieving the most
  rate per cache rewrite first, until it no longer would. Sessions whose
  next turn comes soon go before one deep in a turn that began more than 15
  minutes ago and is still sending (`SessionPacer.movable`), since a move
  applies only at a session's next turn. A session moves
  only to an account that, with the session's rate and the cost of writing
  its context into that account's cache, stays within its own window. The
  router moves it at its next turn (`RouterState.moves`).
- An account that would reach its limit only shortly before its reset keeps
  its sessions. When one of them is refused at the limit and the reset the
  refusal names comes within five minutes and at least a minute before the
  session's cache expires (`RouterLogic.holdUntil`), the router holds the
  streamed request. Five minutes is `RouterLogic.maximumHold`: Claude Code
  keeps a stream carrying only comments open for over five minutes, but
  abandons it and sends the request again within twelve. A longer wait goes
  to the next pool account at the limit, as before. A held request gets the 200
  event-stream head goes out at once, a comment follows every 14 seconds,
  and the request goes to the same account again after the reset. Errors
  after that head are written as `event: error`.
- An account at its limit, or within `suspensionLead` of it, whose limiting
  window resets more than five minutes away but at least a minute before the
  prompt caches of its working sessions expire, holds those sessions
  (`AppState.holdSessionsForImminentReset`) instead of letting the router
  move them onto an account that writes their whole context again. Only
  sessions with at least `heldCacheMinimumContext` tokens of context are
  held. The pause file names the account (`PauseFile.account`) and holds
  them at their next tool call, not their new turns; they continue on that
  account once it has reset, through `admitPausedSessions` restricted to it,
  or wherever capacity is ten minutes after the reset if no reading shows
  it. One reset holds its account's sessions once.
- New sessions go to accounts by unused rate, the pool weight times the
  rate the account can still add without reaching its limit; with none
  left anywhere, by the pool weights alone.
- A session that starts a turn after its cache has expired is placed again
  like a new session (`RouterState.cacheAwareSessions`), since moving it
  loses nothing.

While sessions are served from several accounts, pausing waits for the whole
pool: sessions pause only when no other included account is below its limit
with more than `suspensionLead` to go, because each account keeps serving its
own sessions and the router moves a refused request to the next. With every
account at its limit the pool falls back to the active account alone
(`activePool`), which the failover plan made the one on extra usage or the
one that resets first. An account serving on extra usage pauses nothing,
and sessions paused before it took over continue.

### The one-hour prompt cache

On a subscription within its usage limits, Claude Code asks for the
one-hour cache for its main conversation (`promptCacheTtl`, automatic), and
for five minutes for subagents, workflow agents and background requests
(`subagentPromptCacheTtl`) and for every request while the account is on
extra usage. Forked agents carry the parent's whole context, so in a session
that runs workflows most of its large-context requests are five-minute ones.

Setting `promptCacheTtl` and `subagentPromptCacheTtl` to `"1h"` in
`~/.claude/settings.json`, with `CLAUDE_CODE_PROMPT_CACHE_TTL`,
`CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL` and `ENABLE_PROMPT_CACHING_1H` in its
`env` for versions that predate those settings, gives every request the hour
from Claude Code itself, extra usage included, as each session starts.
AccountDock does not write these.

With **Keep prompt caches for an hour** (on by default), the router also
rewrites every `cache_control` mark of every request to `ttl: "1h"`
(`RouterLogic.withExtendedCache`, `RouterState.extendedCacheMinimumContext`
set to 0), on Claude accounts only, which reaches sessions started before
those settings. Every mark gets
the same lifetime, which keeps the API's rule that longer-lived marks come
first. A one-hour cache write costs 2× input against 1.25× for five minutes;
a read after an idle spell of five to sixty minutes then costs 0.1× instead
of a full write again. The longer lifetime also lets pacing and the reset
holds above count on an hour.

Usage reports the one-hour part of each write
(`cache_creation.ephemeral_1h_input_tokens`, `TokenCounts.cacheWriteLong`),
which `TurnCostModel.weighted` prices at 2. `CacheExtensionLedger` keeps a
week of what the hour saved (cache reads after a five-to-sixty-minute gap,
at 1.15 per token) and what it cost (0.75 per one-hour write token), shown
under the setting.

`SessionRates` is saved with the rest of what AccountDock learns, so a
restart keeps every session's rate, demand history and turn start. A quiet
session's history is kept for eight days (`SessionRates.retention`), so a
session paused for days still has its own forecast.

### Resuming as capacity allows

With **Resume sessions as capacity allows** (on by default, for the routed
provider), a pause does not end all at once. Each failover cycle,
`AppState.admitPausedSessions` lets paused sessions continue where their
forecast use fits (`SessionPacer.admit`):

- A session's forecast is its average weighted tokens per hour over the hour
  before it was held (`SessionRates.heldDemand`): before the pause began, or
  before its last request when it was resumed and held again. Idle time is
  included, so one
  waiting on its user between turns forecasts little and one working on its
  own forecasts its steady rate. A session with no history takes the median
  of the paused sessions that have one.
- Tokens become window percent by each account's own ratio
  (`TurnCostModel.ratio(for:)`), learned from its readings, since plans of
  different sizes count the same tokens differently.
- The accounts are the router's pool while sessions are served from several
  accounts, otherwise the active account; each must be read recently, below
  its limit and not about to reach it.
- Sessions are placed largest forecast first, each where the account, with
  the sessions already running there, reaches none of its limits before the
  window resets; a session held mid-turn on an account that can still serve
  stays on it. Smaller sessions fill what is left, so a small one never takes
  the place of the main worker while both cannot fit.
- An account that would still leave at least 2% unused by its reset takes
  the largest remaining session that may run there as surplus.
- Each resumed session's rate restarts at its forecast (`SessionRates.resume`)
  so it counts against its account at once, and the router sends it to that
  account at its next request (`RouterState.moves`, applied mid-turn when its
  own account cannot serve).
- `reholdSessionsNearLimit` holds a resumed session again at its next tool
  call when its account is at its limit or within `suspensionLead` of it, and
  a surplus session once its account has only what its other sessions need.
  The pause ends when it holds no session. Single steps within headroom
  (`releaseStepsWithinHeadroom`) are not used meanwhile.

The user's own pause still ends whole, and a provider without router token
counts resumes as before.

### Lifecycle

`RequestRouterController.reconcile(wanted:)` runs every two minutes. When a
setting needs the router, it installs the launch agent if missing and restarts
it when the running build differs from the bundled one. When no setting needs
it, the `ANTHROPIC_BASE_URL` entry is removed at once, and the app unloads and
removes the agent once it has served no request for 30 minutes, so sessions
still pointed at it can finish. The configurator never replaces a base URL that something else set.

### Credentials and trust

The router never reads the Keychain and stores no tokens on disk. The app reads
the credentials it needs from its own Keychain copies and pushes them to
`/__accountdock/credentials`, authenticated by a random key in
`Router/control.key` (mode 0600). The router keeps them in memory only. If it
restarts while the app is not running, it passes requests straight through to
Anthropic until the app pushes credentials again.

- Requests with an `Origin` header or a non-loopback `Host` are refused, so a
  web page cannot use the router.
- The account pool and the route target are used only for clients whose own
  credential fingerprint (a truncated SHA-256) is one of the user's accounts.
  Any other client is passed through with its own credential. The app keeps
  the fingerprint map for a day across restarts, because a running session may
  hold a token that is no longer any account's current one.

### Routing a request

1. Read the session ID from `metadata.user_id` (a JSON object with
   `session_id`, or a string ending in `_session_<id>`) and whether the request
   starts a new turn (its last message is the user's own, not tool results).
2. Choose the backend: a turn finishes on the backend it began on when the new
   backend would reject its thinking blocks.
3. Remove thinking blocks the chosen backend would reject. Signatures are
   tracked per issuer (backend and account), and an account that rejects
   another's signatures is learned.
4. Choose the pool account: the session's own within a turn; at a new turn,
   the active account (or, with distributed sessions, the least-loaded account
   with weight); accounts without weight only when every weighted one has
   refused.
5. Forward. A refusal at a plan limit (`anthropic-ratelimit-unified-status:
   rejected`) is replayed on the next pool account, then on the route target,
   and the app no longer considers the refused account until its reset. A
   connection that drops before any reply is retried up to three times on a
   fresh connection; client sessions are spread over several upstream
   connections, so one dropped HTTP/2 connection affects few of them.
6. Adapt the request for a route target. A target without server-side
   conversations gets no request carrying `thread`: the router answers it with
   the error Claude Code recognises (`details.error_code:
   thread_unsupported_request`), and Claude Code resends the turn whole and
   keeps that session's requests whole. A target without deferred tools gets
   the request without the deferred tools the conversation never used, the
   tool-search tools and Anthropic's server-tool blocks. A session whose context
   exceeds the target's cap stays on the pool.
7. A route target never gives the final answer. When it refuses at its limit
   (Kimi answers 403 "You've reached your 5-hour usage limit") the router
   skips it for every session until the refusal's reset and sends the request
   to the pool; when it rejects a request as invalid (400), the structure of
   the request, without its text, is logged and the pool answers. A session
   out of every option therefore gets Anthropic's own limit reply, with the
   `anthropic-ratelimit-unified-*` reset time Claude Code waits for before it
   continues the session by itself.
8. Copy the reply to the client as it arrives. When the client closes its
   connection, as when a user interrupts a turn, the upstream request is
   cancelled so the backend stops generating, and the connection is closed.
9. Record usage headers, token counts (cache reads separately) and events for
   the app.

`RouterLogic` holds every decision as pure functions, which the tests cover
directly.

### Adding a route target

A route target is a `RouteTarget` (base URL, authentication, models, the
request protocol it accepts, whether it validates thinking signatures, keeps
server-side conversations or understands deferred tools, its default context
cap and window cost per million tokens) set as its provider's `routeTarget`
capability, and a case in `AppState.accessCredential` that supplies its token.
It is offered to the routed provider when it accepts the protocol the router
serves that provider with. The router itself needs no change.

### Serving a Responses CLI from a route target

Codex speaks the OpenAI Responses API, which no route target accepts.
`ResponsesBridge` rewrites a Responses request as a Messages request and the
backend's streamed reply as Responses events, so a target can serve Codex
sessions while every Codex account is exhausted. It is off unless the user
turns on **Send Codex requests through AccountDock's router**
(`ProviderFailoverPolicy.routeThroughBridge`) and chooses a target
(`usesBridge(for:)`); while off nothing of Codex's is read or written for it.

- **Reaching the router.** Codex's `requestHold` capability names
  `openai_base_url`, a key before any table in `~/.codex/config.toml`: the
  base URL of Codex's built-in provider, which keeps sending the account's
  sign-in there. A hold with `bridgedProtocol` is installed by that setting
  alone, never by pausing (`ProviderRequestHold.wantsRouter`): the key is set
  to `/__provider/codex` once the router's agent is installed, the upstream
  (`https://chatgpt.com/backend-api/codex` when the key was absent) is kept in
  `Router/passthrough.json`, and the key is removed again when the setting is
  turned off. `RequestRouterController.reconcile(wanted:bridgeWanted:)` runs
  the agent for the bridge without pointing Claude Code at it. Codex first
  asks for a websocket; the router answers 426 and Codex uses HTTP for the
  rest of the session. Its requests carry the session as `prompt_cache_key`
  and the `thread-id` header. Only sessions started after the key is set
  reach the router, and those started from another `CODEX_HOME` do not.
- **Until a route starts** every request is forwarded unchanged to the
  upstream with the client's own credential (`ProviderPassthrough`). Codex's
  entry has `holdsRequests: false`: its gate hook waits for a whole pause, and
  Codex gives up on a reply that stays silent for five minutes.
- **Routing.** The app chooses the target as for Claude Code
  (`routeTarget(for:)`, `routeTargetAccount`, `RouteCapacity`) and publishes
  `RouterState.passthroughRoutes[<key>]`: `routed` while the provider's
  accounts are exhausted (`holdWork` → `routeToTarget`), `fallback` while the
  target can take a request the provider refuses with 429 and no other
  account of the provider could (the router holds no pool of its accounts,
  so the refusal otherwise reaches the CLI and failover switches). The route is used
  only for a client whose credential fingerprint is one of the user's
  accounts, and only for `POST /responses`; every other path goes upstream.
- **The request.** `instructions` and leading developer messages become the
  system prompt; function, namespace and free-form tools become Messages
  tools (`ToolNames` maps flat names back; a free-form tool takes one `input`
  string), read from `tools` and from `additional_tools` input items; tool
  calls and outputs become `tool_use` and `tool_result`, each call answered;
  images are kept; encrypted reasoning and hosted tools are left out.
- **The reply.** `ResponsesStreamTranslator` writes `response.created`, each
  item's `added` and `done`, text deltas, and exactly one closing event:
  `response.completed`, `response.incomplete` when the backend stopped at its
  output cap, or `response.failed` (with the response's own ID) when the
  backend reported an error, its stream ended without `message_stop`, or the
  connection dropped. A tool call still open at a failure is not reported
  done. An error after a held Responses stream's head is a `response.failed`
  event too (`ProviderPassthrough.streamError`). Token use is counted by
  `RouterLogic.StreamUsage`, which `SSEScanner` shares.
- **Events.** The router's events for these requests carry `client`, the
  provider's key; the app applies them to that provider (`applyBridgeEvent`)
  and to the target's learned cost, never to Claude sessions.

### When a route target serves

A target can fill its window far faster than a Claude account, because it
counts every routed token, cached or not: on Kimi, one request carrying a
300k-token conversation uses about 1% of the 5-hour window. `RouteCapacity`
decides whether routing starts or continues:

- the target's window, estimated between readings from the tokens routed since
  the last one, must stay above the share kept for the target's own sessions;
- at the busiest five minutes of the last hour of demand from sessions within
  the context cap, the target must last at least the configured time;
- the cost of a routed token is learned per target from its account's readings,
  starting from the target's default.

While routed, the target's account is read every cycle. A refusal at the
target's limit is applied straight away (see step 7 above).

## Hooks

AccountDock installs its hooks additively and backs up each settings file once
before the first change. Settings → General → Agent hooks shows each
component's state and can reinstall them, and the app asks on launch when any
are missing.

Each component is a provider and a kind (`lifecycle`, `liveUsageFeed`,
`pauseGate`, `router`), offered when the provider's capabilities declare it and
required when its CLI is installed and the feature is on.

| Component | File changed | Purpose |
| --- | --- | --- |
| Claude Code session hooks | `~/.claude/settings.json` | Record session ID, directory and state for recovery |
| Claude Code live usage | `~/.claude/settings.json` (`statusLine`) | Pass rate limits to AccountDock, then run the user's own status line |
| Claude Code pause gate | `~/.claude/settings.json` (`PostToolUse`) | Pausing sessions |
| Claude request router | `~/.claude/settings.json` (`env`) | `ANTHROPIC_BASE_URL`, only while a router feature is on |
| Codex session hooks and pause gate | `~/.codex/hooks.json` and managed homes | Same, for Codex builds with lifecycle hooks |
| Kimi Code session hooks and pause gate | `~/.kimi-code/config.toml` | Marked `[[hooks]]` tables |
| Request hold (Codex, only with its bridge setting on) | The CLI's config (`openai_base_url` in `~/.codex/config.toml`) and `Router/passthrough.json` | Sending model requests through the router: a route target for Codex; holding requests for a whole pause for a CLI that needs it (none today) |

Session records contain no prompt or transcript content.

## Files

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/AccountDock/Sessions/` | Session lifecycle records |
| `~/Library/Application Support/AccountDock/Pause/` | Pause lists and one-step release files |
| `~/Library/Application Support/AccountDock/bin/` | Generated hook and status-line scripts |
| `~/Library/Application Support/AccountDock/Router/` | Router state, control key, events, usage observations, thinking signatures |
| `~/Library/Logs/AccountDock-app.log` | App log |
| `~/Library/Logs/AccountDock-router.log` | Router log |
| `~/Library/Logs/AccountDock-failover.json` | Failover activity log (account identity obfuscated, capped at 500) |
| `UserDefaults` `app.accountdock.mac` | Accounts, usage snapshots, failover settings and runtime, learning |

## Costs

Costs are computed locally from session logs: Claude Code's JSONL transcripts,
Codex rollouts and Kimi Code sessions, priced from `litellm-pricing.json`.
Claude Code turns the router served from a route target name the target's
model in the transcript; they count as the target provider's usage, priced as
its model, and are left out of Claude's totals.
Claude totals must match `ccusage`; see [COST_VERIFICATION.md](COST_VERIFICATION.md).
A small index of per-file token totals avoids re-reading unchanged history and
stores no prompt or response content.

## Distribution and updates

`project.yml` owns the shared app/widget marketing and build versions. The
fresh AccountDock history starts at `1.0.0` (build `1`).

`UpdateChecker` performs a read-only request to the latest-release endpoint for
`bbmumford/AccountDock`. It accepts only HTTPS GitHub download URLs and releases
containing `AccountDock.pkg` plus a valid 64-character SHA-256 sidecar. The app
does not download the package, mutate `/Applications`, or invoke a shell. It
renders a command for the user to copy and inspect.

The command verifies transport, digest, Installer signature, and Gatekeeper
assessment before invoking `/usr/sbin/installer`. Release CI is responsible for
Developer ID signing, Apple notarization, stapling, and publishing the digest.
The local release helper never pushes; publication requires an explicit
separate Git operation.

The application group is `$(DEVELOPMENT_TEAM).app.accountdock`, resolved from
the signing team at build time. This prevents a release from inheriting the
upstream project's Team ID.

## Settings window for a menu-bar app

Because AccountDock is a pure menu bar application (`LSUIElement` = `true` in `Info.plist`), SwiftUI's native `Settings { ... }` scene and `SettingsLink` often fail to open or gain foreground focus. This happens because SwiftUI does not consider the application to have any active interactive scenes when only a `MenuBarExtra` is present.

To circumvent this macOS limitation, AccountDock uses the **Lifecycle Keepalive** pattern:

1. **Hidden Keepalive Window:** At startup, we declare a 1x1 pixel `WindowGroup("AccountDockKeepalive") { HiddenWindowView() }`.
2. **True Invisibility:** The `HiddenWindowView` intercepts its own NSWindow on appearance and sets it to be `[.borderless]`, `alphaValue = 0`, positioned far off-screen (`x: -5000, y: -5000`), and configured to ignore all mouse events.
3. **Triggering Settings:** `HiddenWindowView` listens for a custom `Notification.Name.accountdockOpenSettings` via Combine. When received, it invokes the native SwiftUI `@Environment(\.openSettings)` action.
4. **Invocation:** In `MainMenuView`, when the user clicks the Settings gear icon, we post this notification. The hidden window (which SwiftUI recognizes as a valid, active scene) catches it and smoothly opens the native Settings window with proper focus.
