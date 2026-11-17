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

The app runs every other program through `CommandRunner`: output is read
while the program runs, a time limit or a cancel stops it with `SIGTERM` then
`SIGKILL`, secrets go on standard input, and standard error is kept apart,
merged or discarded; `start` launches the few programs that outlive the call
(the pause watchdog, the update helper). Every question about running
processes is asked of a `ProcessTable`: pid, parent, terminal, the exact
command (`ps -axww`) and the environment (what `ps -axEww` adds after it).
The quota cycle reads one fresh (`refreshSlotProcesses`) and terminal lookups
reuse it while it is a few seconds old; readers that act on a process at once
read their own. `CommandRunnerCoverageTests` fails for a launch outside the
runner or a `ps` outside the table.

What an account's card on the usage tab and its row in the account list say
about it (Active, its plan and why the plan cannot serve, needs sign-in, a
failed or stale reading, credentials to capture again) is one
`AccountStatus`, decided by `AccountStatus.make` and kept in
`AppState.accountStatuses`, which is recomputed whenever the accounts, their
readings, their reading errors or the rejected sign-ins change; the views
only draw it.


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
| `sessionIsolation` (`ProviderSessionIsolation`), `backgroundSessions` | One-session slots and their launcher, through the provider's own credential location, slot variable and resume options; recognising the CLI's background-session workers and attach clients |
| `liveUsageFeed` | The status-line usage feed and its setting |
| `requestRouter` | Which provider's CLI the router serves (`AIProviderType.routedProvider`) and the routing settings |
| `routeTarget` | The service the provider offers as a route target |
| `supportsExtraUsage` | The extra-usage setting and card row |
| `reportsModelWeeklyLimits` | The menu-bar module for the active account's tightest model-scoped weekly limit |
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
  `SessionAttribution` decides the account serving each session, for the
  account cards' counts, transcript learning, pacing, holds and moves alike:
  the slot it reads, else the router's account within ten minutes, else the
  account its own status line matched by reset times (never one of two
  accounts sharing their weekly reset, as two sign-ins of one subscription do,
  unless a session reset matches one alone: `AppState.matchByResets`), else
  the account its
  last recorded request was on (both only when seen after its sessions were
  last signalled to read the sign-in again, and within a session window),
  else the live credential's owner, else the active account. A session on
  the shared sign-in keeps the token it read until it is signalled, so it
  stays on the earlier account after a switch.
- **Transcripts.** `TranscriptRequestFeed` reads each provider's session
  transcripts through its `ProviderCapabilities.transcriptSource`, which
  lists the files and says what each row records: per request the session,
  time, model, input, cache and output tokens, whether it started a turn,
  the subagent that made it, the session's name, and usage-limit refusals in
  the provider's words. `ClaudeTranscriptSource` reads `projects/`,
  `CodexTranscriptSource` the rollouts under `sessions/` (and names from
  `session_index.jsonl`), `KimiTranscriptSource` each agent's `wire.jsonl`
  (and titles from `state.json`). `AppState.ingestTranscriptRequests` learns
  request cost, models, names and refusals for every provider with a
  source, whether or not the router serves it.
- **Cost and activity.** `CostParser.ProviderCostHistory` holds each
  provider's daily cost and today's turns, models, lines, tokens, sessions and
  active time. Claude Code's is built from its per-request cost summary; the
  others from their per-day, per-model aggregates. `TodaySummary` sums today's
  figures over the providers the user has not hidden, each metric over the
  providers whose `activityMetrics` report it; the usage dashboard, the cost
  tab, the menu bar and the widget all read it and write costs and tokens with
  `UsageFormat`, which also writes every time and span AccountDock shows:
  a time of day, a weekday and time within six days, or a date beyond
  (`clock`); spans as "2 hr 14 min" (`duration`) or, in narrow cells,
  "2h 14m" (`compactDuration`); and a window's reset as "Resets in …" or
  "Resets on …" (`reset`).

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

The token JSON carries no identity, and running sessions on the shared sign-in
renew the live token and write their own account into `~/.claude.json` at any
moment, so neither the moment of a read nor the identity file says whose a live
token is.

Signing in a new Claude account and re-authenticating one never touch the live
sign-in (`ClaudeIsolatedLogin`): `claude auth login` runs with
`CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR` both set to a new
temporary directory. The CLI (read from its 2.1.311 build) then keeps the
credential in the Keychain item `Claude Code-credentials-` plus the first eight
hex digits of the SHA-256 of that path, the item the session slots use
(`ClaudeSessionIsolation.keychainService`), or in `.credentials.json` there, and
the identity in `.claude.json` inside `CLAUDE_CONFIG_DIR`. AccountDock reads
both, asks the profile endpoint whose the credential is, saves it as that
account's copy (a new account, a refreshed existing one, or the account being
re-authenticated; another account's for a re-authentication saves nothing),
and removes the directory and its Keychain item. No session can race the
sign-in and no account has to be switched back afterwards; only the first
account of the provider, or a re-authenticated active one, is installed as the
live sign-in.

Every capture of the live token itself (adding the account the CLI is signed
in to, the backup of the outgoing account before a switch, the copy kept after
one, a renewal of the live credential) goes through
`AppState.captureOwnCredential`: the profile endpoint is asked whose the token
is, and it is saved only as that account's copy. A token that is another saved
account's is saved for that account instead when newer than its copy, and the
slot is read again a second later, up to `captureAttempts` times; when it never
is the account's, nothing is saved and adding the account says why.
The identity saved is the live one when it names the account, else the one
saved with its copy. A saved copy whose ownership the provider has not yet
confirmed (no request allowance, or no answer) reads no usage for its account
(`AppState.recordsReading`); the check is made again at the next reading, and a
reading the user asks for always makes it.

### Credential audit

Every read of a credential for use, every write, removal, renewal,
ownership answer, switch, session signal, warm-up and slot change, for every
provider, appends one JSON line to `~/Library/Logs/AccountDock-credentials.jsonl`
(`CredentialAudit`). An entry names the action, the account AccountDock
attributes it to, the code path (`reason`), the slot, session and process
for slot actions, and the token only as a fingerprint: the first 12
hexadecimal digits of the SHA-256 of its access token. No token text and
nothing of a refresh token is written; plan fields (`subscriptionType`,
`rateLimitTier`) are.

The audit learns whose each fingerprint is from the provider's answers
(profile checks before saving or switching, isolated sign-ins, the saved-copy
check before a reading, a Codex token's own signed identity) and keeps the
map beside the file. A later entry with a known fingerprint names the real
owner; one attributed to another account is marked `mismatch` and raises an
event once per token and account.

The trail also records which account served each session and agent
(`served`, once per change), a session's or agent's prompt cache rebuilt
whole right after a warm read (`servedChange`, the change of account the
transcript itself shows), and what a running process's status line or
refusal reset times say about the token it holds (`processCredential`).
A refusal names its reset as a time of day ("resets 2am") for a five-hour
limit and as a day and time ("resets Nov 20 at 12pm", "resets Mon 7:59am")
for a weekly one; the one account whose window resets within ten minutes of
it refused the request. A process holding another account's token than its
slot's or the live one is flagged with an event, whether it reads a slot, the
shared sign-in or runs in the CLI's background service, and flagged again by
every later piece of such evidence; Settings → General → Audit, or the request
`{"action":"signalSessions"}`, tells it to read its sign-in again. Only a
session whose process runs now (a live lifecycle record whose process the
process table lists) is recorded and flagged: a status-line file or a
transcript outlives its session, and a session that ended has no token to
read again, so its flag is dropped. A status line repeats the resets of its
session's last reply and is redrawn without a request, as when a held or
quiet session's user answers it, so a slot session's status line is no
evidence until the session has sent a request after its slot last moved and
settled (`AppState.statusLinePredatesSlotMove`, by the requests its
transcript or the router recorded, `lastRequestSeen`); until then it is no
reading of the slot's account either.


Query it with the request `{"action":"audit","since":"<ISO time>","account":"<id, label or email>"}`;
Settings → General → Audit opens the file. `CredentialAuditCoverageTests`
reads the sources and fails for any credential operation called without a
`reason:` outside a function that records an entry.

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
- This lack of embedded identity is why AccountDock asks the profile endpoint whose a live token is before it saves it under an account.
- `subscriptionType` and `rateLimitTier` are the plan the token was issued under: an upgrade or a downgrade does not change them, and `claude auth status` reports the same. See "Plans" below.

### Plans

A credential keeps the plan it was issued under: a Claude token's
`subscriptionType` and `rateLimitTier` (and `claude auth status`), a Codex
sign-in's ID token, a Kimi sign-in's identity. Each provider declares where
it states the plan an account is on now (`ProviderCapabilities.planAuthority`):
Claude's account profile (`/api/oauth/profile`:
`organization.organization_type` without its `claude_` prefix,
`organization.rate_limit_tier`), Kimi's profile (`/me`:
`user_level_name`), both asked with the account's own credential
(`ProviderCredentialModule.planAnswer`), and Codex's usage reply
(`plan_type`), which comes with every reading. Their answer
(`ProviderPlanAnswer`) is applied by `AppState.applyProviderPlan` through
`Account.applyProfilePlan`, which keeps it with the account
(`profilePlan`, `profileRateLimitTier`, `profileCheckedAt`) and copies it
into the stored plan and tier. Once one has answered, every writer that
reads a credential, a CLI's status or a sign-in's identity goes through
`Account.applyCredentialPlan`, which leaves the plan and tier alone, and
`planSize`, `planHasSessionWindow`, `displaySubscriptionType`,
`workloadAvailability` and the learned plan read the authority's first
(`currentPlan`, `currentRateLimitTier`). An account saved before any
answer decodes as before and keeps its credential's plan until one comes.
An answer naming another account than the one it was asked for is not
applied. An ended plan, in Claude's profile or as a Claude usage reply's
refusal (`markClaudeCodeUnavailable`), is kept as "free".

An endpoint authority is asked after a sign-in, a re-authentication and a
Claude switch, on the user's refresh for every account, and otherwise
every `profileRecheckInterval` (three hours; a check that got no answer is
logged and tried again after `profileRetryInterval`), with the usage
reading of an account or, for accounts only passive readings cover, by
`recheckProviderPlansIfDue` after a refresh's readings, from the background
allowance (`checkProviderPlan`). Kimi's check does not wait on its usage
reply, whose shape follows the plan: a reply is read window by window, and
one with no quota window fails naming the keys it carries. A change of
plan or tier is logged (`[plan]`) and told in the failover events. Kimi
lists no plan sizes, so a Kimi account's cost is learned or plan-wide
whatever its level; a change of level still makes its cost be learned
again (`TurnCostModel.notePlan`).

### Codex and Kimi

Each Codex account has its own managed home directory. Switching copies that
home's `auth.json` into `~/.codex/auth.json` with an atomic rename, so a running
Codex process never reads a half-written file. Each Kimi account has an
isolated copy of Kimi Code's credential file. Kimi rotates its refresh token on
every renewal, so a renewed token is written back to the managed copy before it
is used.

The credential a CLI's sessions share (`~/.codex/auth.json`, Kimi Code's slot)
is renewed by AccountDock only while no process of that CLI runs
(`CLIProcessScan`). Both CLIs read the file again before they renew, but
neither can see a renewal AccountDock is making at that moment: Codex takes no
lock on the file, and Kimi Code, finding its refresh token already used,
replaces the slot with a revoked credential. While the CLI runs, a reading
whose token has expired reports it as expired and the CLI renews it with its
next request. Kimi renewals of one managed copy run one after another
(`CredentialRenewalClient.Queue`), and one that finds the copy already renewed
while it waited uses that result instead of presenting the spent refresh token.

Every provider's token renewal goes through `CredentialRenewalClient`. Each
service describes its endpoint (`TokenEndpoint`: URL, form or JSON body,
client fields, headers, time limit, which replies refuse the grant and which
throttle); the client writes the `refresh_token` request, sends it, and tells
a refused grant (the account needs signing in again: Claude's 401 or 400
`invalid_grant`, Codex's and Kimi's 400 or 401) from every transient failure
(throttling, other statuses, no connection), which leave the stored credential
usable later. A renewal asked for while another presenting the same refresh
token is under way shares that one's reply instead of presenting the token a
second time. Each attempt is written to the audit through
`CredentialAudit.recordRenewal`, as `renewed`, `rejected` or `unavailable`.


`KimiSessionIsolation` is Kimi Code's one-session slot. Every slot runs in
`~/.kimi-code` itself, so all sessions share their history, settings and
hooks. With `KIMI_CODE_BASE_URL` or `KIMI_CODE_OAUTH_HOST` set, Kimi Code
reads the credential named `kimi-code-env-<first 16 hex of sha256>` of the
two values, so a slot is a pair: the real OAuth host, and the real API base
URL with some host letters in upper case, a spelling no other slot holds
(claimed by creating its credential file with `O_EXCL`). URL parsing
lower-cases the host, so every spelling reaches the same server, and model
requests use `config.toml`'s `base_url` anyway. The slot directory holds the
pair (`base-url`, `oauth-host`) next to the shared bookkeeping; the launcher
exports it with `ACCOUNTDOCK_KIMI_SLOT`, which the process mapping reads.
The credential, `~/.kimi-code/credentials/kimi-code-env-<hex>.json`, holds
the account's access token, its real expiry and an empty refresh token,
written by atomic rename while holding Kimi Code's own lock
(`KimiCredentialLock`). Kimi Code reads that file before every request and,
with no refresh token, never renews it, so AccountDock keeps every slot's
token above Kimi Code's renewal threshold (`max(300, expires_in / 2)`
seconds) plus a margin, renewing the active account's credential under the
lock in `~/.kimi-code` (`KimiService.renewLiveCredentialForSlots`). Removing
a slot deletes that one file and nothing else in the home. A session that
finds the server's model list changed writes its own spelling and
credential name into `config.toml`, which would point sessions outside
slots at the slot's credential; every slot pass puts `base_url` and `key`
back (`restoreSharedState`), unless the file that spelling names holds a
refresh token (see [provider-cli-facts.md](docs/provider-cli-facts.md)).

`CodexSessionIsolation` is Codex's one-session slot. Every slot runs in
`~/.codex` itself, so rollouts, history, settings and hooks stay shared. The
launcher puts `-c` overrides before the user's arguments that select a model
provider of AccountDock's (`model_provider="accountdock"`) named `OpenAI`,
which Codex treats as its own, at the ChatGPT Codex endpoint, whose bearer
token comes from a command: `/bin/sh` printing `access_token` from the
slot's `credential.json` while its `account_id` still equals
`ACCOUNTDOCK_CODEX_ACCOUNT_ID`, the account read at launch and sent as
`ChatGPT-Account-ID`. Codex runs the command again every minute and after a
401. `cli_auth_credentials_store="ephemeral"` keeps the session away from
`auth.json`: it never reads, renews or asks for a sign-in. The slot holds the
access token, account and expiry, no refresh token; AccountDock renews each
account (the active one in its managed home and `~/.codex` together,
`CodexService.renewLiveCredentialForSlots`, well before Codex's own window)
and rewrites the slots. Because the account header is fixed for the
process, Codex sessions move by restart (`movesNeedRestart`):
`serveSessionSlots` keeps the slot's account and queues the move, and
`applySlotRestarts`, only for an idle, unpinned session in agterm whose
footer reports no running work, fills a spare of the new account, names it
in the resume file for the session, then types `/exit` and
`codex resume <id>`. The pacer and rebalance cost such a move three times a
cache rewrite (`sessionMoveCostFactor`).

## Claude account switching

`ClaudeService.switchAccount(from:to:)` is transactional: it snapshots the live
token and identity first and restores them if any later step fails.

1. **Back up the source.** Before the switch, `AppState.switchTo` saves the
   live token as the source's copy only when the provider says it is the
   source's (`captureOwnCredential`). When the source and target are the same
   account (restoring the active profile), nothing is backed up: the live
   credential is the one being replaced and must not overwrite the copy being
   restored.
2. **Read the target backup.** An incomplete stored token falls back to the
   backup's previous token; with neither, the switch stops.
3. **Write.** The target token goes into `Claude Code-credentials` and the
   target identity into `~/.claude.json`. Every Claude Code session rewrites
   that file, so `ClaudeIdentityFile` replaces the text of `oauthAccount` only,
   keeps every other byte and the file's permissions, and replaces the file
   only if it is unchanged since it was read, reading it again otherwise.
4. **Verify** (`ClaudeService.verifySwitch`). The provider's profile
   endpoint is asked whose the written token is (the token as `claude auth
   status` refreshed it, when the written one had expired). Running sessions
   rewrite `~/.claude.json` with their own account within a second of the
   write, so the identity `claude auth status` reports cannot confirm or
   refute a switch while sessions run. The profile naming the target
   confirms it, and the target's identity is written again if a session
   replaced it. The profile naming another account, or the provider
   rejecting the token, rolls back to the snapshot and quarantines the
   target (`AppState.switchFailureQuarantines`). When the profile cannot be
   asked, `claude auth status` naming the target and logged in, within
   `ClaudeService.cliTimeout`, confirms it; anything else rolls back without
   quarantine (`switchUnconfirmed`).

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

A reading's provider-neutral form is `UsageReading`: its windows (`Window`,
each a session, long or model window with its percent, reset and length),
extra usage, limit resets and model limits. It converts from and back to the
reply form the providers' readers return (`UsageAPIResponse`), which the
planner, pacer, simulator, views and widget still read. Saved usage
snapshots hold the neutral form (`PersistedUsageSnapshot`), and a snapshot
saved in the reply's form loads, converted.

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
Accounts are read active first, then the accounts sessions run on, then the
idle ones, each oldest reading first (`AppState.readUrgencyOrder`), so the
account at the end of the list is not the one left unread whenever the
budget runs short, and idle accounts at their limits do not spend the budget
before an account sessions are using.
Throttling backs off for every account of that provider, from one minute up to
fifteen. While a provider throttles, `QuotaTrend` projects the active account's
usage forward from its learned burn rate so failover still acts on time.

The budget ranks requests critical (the active account's decision), candidate
(a destination before a switch, an account in use whose reading is too old
for a new session), verification and background (idle refreshes); each keeps
half a request more in the bucket than the rank above it, so background reads
can never spend what verification reads need. A reading that needs a second
request, as the first reading of a Claude saved sign-in does to check it is
the account's own (`savedCopyIsOwn`), pays for it from its own admission
(`UsageRequestBudget.spendFollowUp`).

When an account's reset time passes, its stored windows are cleared and it
awaits a reading that confirms the reset
(`accountsAwaitingPostResetVerification`, kept in the usage snapshots): until
then it is ineligible for sessions and switches, never taken for 0%. A
reading whose reply still names a passed reset does not confirm it. The quota
cycle reads such accounts 30 seconds after the reset, at verification rank
(`verifyPassedResets`), and runs again as soon as a cool-down or the budget
lets the reading through. A passive reading confirms the reset without a
request when it speaks for the windows after it
(`AppState.passiveApplication`). Claude Code redraws a session's status
line when a window resets, without a request, and leaves the passed window
out, so after a reset a status line counts only when its session sent a
request after the reset (`sessionRequestSeenAt`, from the transcripts, or
the router's record) or shows the session window with use: until then its
missing session window is no sign the account has none, a session window it
shows at no use (the provider's moving placeholder) is not a started one,
and it confirms nothing and stands as no live reading, though its long
window is recorded. The usage cache, the endpoint's whole reply, leaves an
unstarted session window in place on an account with one, and confirms
nothing when fetched before the reset. While an account awaits a reading
that confirms its reset, a reading that does not leaves its warm-up to
`verifyPassedResets` (`unverifiedReadingStartsWarmup`).

Window warming (`keepWindowsWarm`) starts an unused, unstarted window with one
non-persistent probe (`performWindowWarmup`), so it resets sooner. The probe
runs at once on a whole reading taken within the last minute that shows the
window unstarted, or, a minute after the provider's reset time, on an
account nothing has used since the reset and whose sign-in is known to be its
own; otherwise the warm-up reads the account first, through the ordinary
reader. A whole reply that leaves the session window out reports it not
started on an account whose plan has one or whose session window has just
reset (`readingHasSessionWindow`), whatever plan name is stored. A session
window is warmed only on an account whose reading carries one, while its
long window has room; a window a probe started is not probed
again for 30 minutes unless another reset passes. A warm-up the budget or a
cool-down holds back runs just after it ends; one that fails otherwise is
retried after 2, 5, 15 and 30 minutes, then waits for the next reset.

A refusal at a usage limit is checked before anything moves for it
(`verifyRefusals`): the account it names is read when its reading predates
the refusal, and, when that reading shows no window resetting at the time the
refusal states, the accounts in use whose readings predate it are read too,
and the refusal moves to the account whose window does. While the reset it
states is no window of the account it names and the reading that would
settle it is held back, it does not count, for up to five minutes. A refusal
is the account's that served the request when it was refused: the slot's
account at that time by its history (`servingSlotAccount`), unless the reset
the refusal states is none of that account's windows; it is then the one
account the slot may have served the request with whose window it matches
(`servingSlotCandidates`: the settled account and any moved to within
`slotMoveSettling` before the request, kept as `SessionRefusal.served` for
the checks that follow), or else the one account of all whose window it
matches (`refusingAccount`). Two accounts resetting at the same time (bytrix
and cybrio at 1:30 am) leave the slot's history to tell them apart, so a
refusal is never put down to the account the slot left. An account
whose reading is older than its pool lifetime is read before it takes a new
session (`FailoverPlanner.poolReadingIsCurrent`) and takes none while that
reading cannot be made.

A session's refusal is one event per limit it states (`AppState.refusalIsNews`,
keyed by `refusalLimitKey`), whether the session's own transcript holds it or
only a subagent's does: a session's subagents are refused one after another
while replies they sent before the limit still land, so neither the count of
refusals nor such a reply starts a new run. A served request answers the
refusal, and clears it, only when the refused agent made it or it comes more
than `refusalInFlightAllowance` after the refusal (`servedAnswersRefusal`).

A reading a running session reports with a response (the status line, a
Codex rollout: `PassiveUsageObservation.Source.reportsWithEachResponse`)
arrives every few seconds while it works, whatever the budget or a cool-down
allows. While such a reading is the account's newest, under two minutes old,
below every trigger and not followed by a refusal, it stands over the
forecast (`FailoverPlanner.liveReadingShowsRoom`): the account is neither
triggered nor near or forecast at its limit, and a router refusal recorded
before it is dropped. It carries no model's own weekly limit; that verdict
stays with the last whole reading, which narrows the long window the planner
sees, and an account with such limits keeps a router refusal until a whole
reading after it.

Claude's response includes every limit it applies, including weekly limits
scoped to one model (`limits[]` with `kind: weekly_scoped`) and the share of the
weekly allowance each may use. The planner uses the model-scoped window that
applies to the model the sessions are using, read from the status line.

An account whose plan does not include the CLI (a free or ended plan) has a
`subscriptionType` that `Account.workloadAvailability` reports unavailable,
and the planner treats it as ineligible. An account whose organisation has
turned off subscription access for Claude Code, as a team admin does by
removing its seat or licence, is refused with HTTP 403 `oauth_org_not_allowed`,
which Claude Code shows as "API Error: Your organization has disabled Claude
subscription access for Claude Code · Use an Anthropic API key instead, or ask
your admin to enable access" (`ClaudeService.refusesCLIAccess`). That refusal,
read from a session's transcript (`ClaudeTranscriptSource.accessRefusal`, at
most `cliAccessRefusalWindow` old), a usage reply (`UsageError.organizationDisabled`)
or a warm-up probe, marks the account (`AppState.noteCLIAccessRefused`,
`Account.cliAccessRefusedAt`, saved with the account), which reuses the
unavailable plan's state: `workloadAvailability` is unavailable ("Claude Code
disabled by organisation"), so failover, slots, pacing and warm-ups leave it
and move its sessions off at once (the quota cycle is brought forward; pinned
sessions are unpinned), a move by hand is refused with the reason
(`Account.cliUnavailableReason`), and the card shows `Account.cliAccessNotice`,
which asks the user to check the seat or licence. `recheckCLIAccessIfDue` tries
the account again with the warm-up's request daily and on the user's refresh;
served, the mark ends.

## Failover, weekly balancing and session balancing

Three mechanisms move work, each with its own code and events:

- **The active account** (`activeAccount(for:)`, the account the shared
  sign-in holds) is moved only by `performAutomaticSwitch`, for
  `FailoverPlanner.plan`'s switch reasons: failover's `.threshold`,
  `.exhausted` and `.workloadUnavailable` (with `policy.enabled`), and weekly
  balancing's `.balance` (with `intelligentBalancingEnabled`), which orders
  accounts by `latestStart`, the latest moment each must start being used
  for its remaining weekly allowance to be spent before its own reset, so an
  account resetting sooner is used sooner. A switch moves every session on
  the shared sign-in (`moveRunningSessions`). Events read "Failover switches
  the active account from …" and "Weekly balancing switches …".
- **Session balancing** moves slot sessions one at a time: the pool's
  weights for new sessions, `SessionPacer.plan`'s shedding, remainder and
  window rules, the stranded placement and lane admission
  (`strandedPlacements`, `admitToLanes`), and the rebalance, all through
  `serveSessionSlots`, whose events read "Session balancing moved …". It
  does not depend on the active account moving.
- **Pausing** (`AgentPauseGate`, `limitPauseScope`) holds sessions account
  by account; the sessions a wait keeps on their account
  (`AppState.SessionWait`: a reset before their cache expires, the active
  account staying, no lane admitting them) are listed in it like pinned ones.

`ProviderFailoverPolicy.activeAccountLocked`, shown as "Move the active
account automatically" (`movesActiveAccountAutomatically`), gates the first
alone: off, `performAutomaticSwitch` makes no switch and records which
mechanism asked (`lockedSwitchEvent`), `nextActiveSwitch` projects none, and
once the active account is at or near its limit
`holdSharedSessionsOnStayingAccount` restarts the shared sessions that can
restart in a slot of their own and holds the rest
(`SessionWait.Reason.activeAccountStays`) until it serves again, the user
moves them or the switch is on again. The menu footer's switches
(`FooterSwitches`, `AppState+MenuToggles`) set it, and `distributeSessions`
for session balancing, for every provider at once; `ProviderFailoverSwitch`
sets it for one.

## Failover planning

`FailoverPlanner` is a pure function from accounts, readings and settings to a
plan: stay, switch, verify (read some accounts, then plan again), wait for a
reset, or no capacity. `AppState+Failover.swift` runs it on a monitoring cycle
and carries out the plan. Only one evaluation runs at a time, because a second
one would plan from a half-switched state.

A plan that every account is at its limit (wait for a reset, or no capacity)
is not acted on during the first ten minutes after launch while an account
that can be read has neither a reading from this launch nor a stored one
still fresh (`AppState.awaitsFirstReadings`). The status the plan's standing
state shows ("Using … up to its limit", "All accounts exhausted …") is
restated every cycle; it is recorded as an event only once it has differed
from the provider's last recorded status for two minutes, the longest quota
cycle (`StatusEventGate`), so two states alternating from cycle to cycle
record nothing. The outcome of an action ("Switched to …") is recorded when
it happens.

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
estimated by `TurnCostModel.switchCost`). Burn rates are taken at their median
plus one standard deviation, so a noisy account is treated as faster than its
average.

A burn rate is the median of the account's last five measured intervals
(`QuotaTrend`), each running until its window has risen a whole point or for
15 minutes, and its spread is estimated from the median absolute deviation,
so one burst sets neither the rate nor its uncertainty. Readings in the five
minutes after a window starts (its reset moves, or an unstarted window gets
one), after a window's use falls within the same window (a reset granted
early, which can leave the reset time as it was), after a slot session moves
to the account, after the router moves a session to it (a routed session's
request seen on another account than its last, `AppState.routedArrival`), or
after paused sessions resume (`AppState.endPause`, an
admission, or a reading taken while the pause holds them) teach no rate:
each session's first request then re-sends its whole context. A failover
switch holds the new account's rate for ten minutes
(`QuotaTrend.arrivalSettlePeriod`), since the sessions on the shared
sign-in arrive together and those between turns send their first request
minutes later.

### Rules, in order

The active account counts as at its limit once the headroom its last reading
shows is less than the **in-flight reserve**: one expected request (from
`TurnCostModel`) for every session active in the last three minutes, capped at
10%. Requests already under way still spend that much after a switch, so work
moves while they still fit. A refusal at the limit, by the router or in a
session's transcript (`AppState.recordedLimitRefusal`), counts the same until a
reading answers it.

Only such a measurement marks an account exhausted (`isMeasuredAtLimit`). A
forecast, the reading grown by the burn over its age, that reaches a limit
the reading does not show (`isForecastAtLimit`) gives `ServingVerdict.nearLimit`:
no new session is placed there (pool weight 0) and it crosses the trigger of
rule 1, but it never makes the exhausted move of rule 3, moves sessions off
the account, or waits for a reset; the account serves on until a reading or a
refusal shows the limit.

Every switch destination must carry the work that moves to it
(`FailoverPlanner.carries`): the shared group's rate (`expectedBurn`, the
active account's burn less its slot sessions, beside the destination's own
slot sessions) plus one deviation, or the destination's own measured rate when
larger, for an hour (`projectedCarry`, the lifetime of the caches the move
writes) or until the window resets when sooner, on each window it has: the
5-hour window at the session rate, the weekly window at the weekly rate. An
account without a 5-hour window has no learned session rate, so its weekly
rate is converted by the plan's ratio. A rate that would spend a whole window
within the hour needs room for as long as half an unused window would carry
it (`burstCarryShare`). An account a few percent from its weekly limit passes
the dwell margin of `tier` but is no destination.

1. The active account crosses a threshold (or will within the lookahead):
   switch to the first account below its thresholds that carries the work, in
   the user's order.
2. No such account: keep serving up to the provider's 100% limit. Moving to an
   account that is merely less full than its threshold adds no capacity and
   causes switch loops.
3. At its limit: move to the usable account with the most headroom that
   carries the work, and has at least the in-flight reserve, the switch cost
   and ten minutes of the moving burn (`destinationMinimum`). A smaller sliver
   would be spent before the move paid off; with none, step 5 waits.
4. Every allowance spent: serve on extra usage if the user allowed it and the
   monthly spending limit has room.
5. Otherwise: wait for the account whose limiting windows all reset first. A
   session-limited account is not ready while its weekly window is still spent.
   The active account is judged at the margin it is held at in step 3 (the
   in-flight reserve), so an account held at 98% waits for its own reset
   instead of an account whose weekly window resets days later being
   prepared, which had switched between the two every minute.

A switch moves only the work on the shared sign-in: sessions in one-session
slots stay on their accounts. Each account's slot sessions' rate is its
`QuotaAccountState.stayingSessionBurnPerHour` (`AppState.withStayingBurns`),
so a destination is judged for the work that moves (the active account's
burn less its own slot sessions) beside the slot sessions already on it
(`FailoverPlanner.expectedBurn`), and the shared sign-in is not switched
onto an account its slot sessions are about to exhaust.

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
advantage and dwell prevent oscillation. Without a session window nothing caps
the pace, so the latest start is the reset itself, and the event's figure
("must start being used N hour(s) before …'s") is how much sooner the
destination resets. A balance switch moves the whole shared group, so its
destination must carry the moving work as any switch destination must
(`FailoverPlanner.carries`); a remainder too small for that is spent by slot
sessions and new sessions the pool sizes to it, never by the group. The
moving work counts at no less than the shared group's own rate and a
typical session's (`Settings.balanceMovingTokensPerHour`, from
`AppState.balanceMovingRate`), since the sign-in also starts every session
launched outside a slot, and an active account held at its limit learns a
rate near nothing just when that work waits to resume: a Max 5x window with
13% left for 39 minutes takes no balance switch from a Max 20x window that
has just reset. `remainderSpending` judges the accounts too small for the
group at the same rate.

With pacing on, `SessionPacer.plan` spends such a remainder
(`SessionPacer.RemainderSpending`, built by `AppState.remainderSpending`):
an account in the pool, other than the active one, that fails `carries`
and whose weekly allowance the accounts' present rates would leave unused
at its reset takes the lightest slot session (by `SessionPacer.lightRate`,
the larger of its current rate and its last hour's) that is between turns
(quiet for `betweenTurns`, and not working by its record) yet still spends
(`SessionPacer.spends`: at a rate above nothing, heard from within
`idleAfter`, 15 minutes, or using tokens over its last hour and heard from
within it, as a session its user answers every half hour does; such a
session is a candidate although quiet past `activeWithin`), not pinned, not
on a draining account and not on another such account, whose use until the
reset plus its cache rewrite (`moveCost`) fits in what is left, keeping the
account within every window and its model's own allowance, and whose move
is worth its rewrite (`SessionPacer.worthMoving`): the use it makes by the
account's session-window reset (by the weekly reset for an account without
a session window) is at least `remainderWorth` (2) times the rewrite, or
exceeds it by `minimumLeftover` (2%), a net gain of room. A second session
follows only while more than half of the remainder would still go unused.
Accounts that reset first are served first; the account carrying the
group's share, now or from the projected switch, spends nothing this way,
and an account giving sessions up takes none. The move goes through the
pacer's moves and `serveSessionSlots`, which records "Moved session X
(light use) to Backup to use its last 2% before it resets on Mon 7:59 am;
it rebuilds its cache there." (`AppState.remainderMoveEvent`) and keeps
that account among the accounts it offers, but resting
(`RemainderSpending.resting`, from `AppState.remainderMovedAt`): for
`balanceMoveInterval` it takes no further session, yet it is still no
carrier, so the shedding rule and a rebalance do not take the session
straight back. It rests only while a slot session on it spends, or for
`idleAfter` after the move while the session's first turn there is still
to come: a session gone idle uses none of the room, and resting the account
would keep away the sessions that would. A session placed so reaches no limit there before the
reset, so shedding leaves it; if the account reaches its limit after all,
the session moves on as any stranded slot session does.

A small plan's 5-hour window is a refilling allowance: room it has left at
its reset expires, and the window starts again full. While the accounts that
take sessions for the runway will together have spent what they hold before
the reset that refills them (`SessionPacer.windowsWorthSpending`: each
reaches a limit before its binding window resets, and their joint run-out
comes before the first of those resets), every percent they hold is spent
before that reset whatever moves, so making the first run-out later gains
nothing and the work served before that reset is what counts. The pacer then
spends the session windows of the accounts `remainderSpending` offers
(`SessionPacer.spendWindows`): each window's room is what its reset would
leave once its own rate has run; one at a time, the slot session between
turns whose arrival costs the fewest tokens per hour it then stays goes to
the window where that is least, so small contexts and light rates go first
and heavy sessions spread over the windows by their token room. A session
goes only when it spends (`spends`), its whole arrival write fits and its
move is worth that write (`worthMoving`: the use it makes of the room, which
is room freed where it was, is twice the write or exceeds it by
`minimumLeftover`), so an 800k-token session moves only into room no cheaper
session takes and 892k tokens of context are never rewritten to move 0.4M an
hour; 19496bb9's 0.5M an hour and 295k of context go into a fresh Pro window
two hours from its reset (5.3% to arrive, 8.9% of use); and only
when that write and its rate until the reset, or for `newSessionRunway`
when the reset is later, fit `windowFitShare` (90%) of the room. A window's
last few percent before an imminent reset take a session sized to them (5M
an hour fits bytrix's last 6% for half an hour; 33.8M an hour would spend
them in ten minutes and be refused until the reset), and a fresh window
takes a heavy session it carries for the hour. New sessions go by the tokens per
hour each account would otherwise leave unused: the windows' room until
their resets, and a carrier's room until the first carrier's reset, which is
none once its own sessions spend it, at most its even rate
(`SessionPacer.evenRate`, under Session pacing). `serveSessionSlots` records "Moved
session X from Personal to hexorda, using hexorda's session window until
12:20 pm, …" (`AppState.windowMoveEvent`).

Every such move, the pacer's or a rebalance's, is a **window placement**
(`AppState.windowPlacements`): the session is planned to stay on that
account until its window is used up or the placement's "until" time, and
every rule that moves slot sessions follows that one intent. While the
session's slot serves the account, "until" has not passed and the session
spends, heard from within `idleAfter` or placed that recently
(`AppState.windowPlacementsInForce`, `placementHolds`), `SessionPacer.plan` and `rebalance`
take it as a session that stays, and the account it fills
(`Plan.filling`, `Rebalance.filling`) as filling as planned: reaching its
session window's limit is no reason to shed (only a weekly limit binding
first still is), the shedding rule sends it no session given up elsewhere,
a stranded session goes there only when nothing else can serve, and
rebalancing settles it, neither moving a session off it or onto it nor
counting its planned fill as a run-out to improve, so neither the manual
nor the automatic rebalance undoes the move. A window that fills, or
refuses, leaves its sessions to the stranded placement above, so they move
on to the next account with room, and a window spent again once it
refills. The shared group stays where `FailoverPlanner.carries` lets it.

The events tell each placement as one story. The move into the window says
until when (`windowMoveEvent`, for a rebalance's window moves too), and the
move that takes the session off says why (`AppState.windowLeaveReason`):
"Moved session X from hexorda to Backup: hexorda's session window is used
up, as its placement there until 12:57 pm planned.", or "hexorda refused it
at its limit, ending its placement there until 12:57 pm", or, for a later
move, "since its placement on hexorda's session window ended at 12:57 pm as
planned". No event says an account a placement fills gives sessions up for
reaching that window's limit, since the pacer does not shed it. A move the
automatic rebalance makes says so ("the automatic rebalance makes the
sessions last longer that way"), and its summary reads "Rebalancing sessions
automatically: …", rather than "a request asked for it".

For new
sessions, `carriesNewSession` and the pacer's runway rule let such an
account take one while it can carry a typical session for an hour, and the
pacer weighs it by the room it has left, a small share beside an account
with most of its week. One that cannot carry a typical session for the hour
still takes new sessions when its session window would otherwise leave room
unused at its reset, at its own rate, at least `minimumLeftover` (2%)
(`SessionPacer.expiringWindowRate`):
the next session's rate is not known when it starts, and that room is lost
whatever moves, so a light session may as well use it. `buildPool` keeps
such an account open (`AppState.windowShare`, the room's tokens per hour
until the reset over a typical session's rate, at most 1, which is its
weight when pacing is off), and the pacer gives it a weight sized to that
room, in tokens per hour, beside the accounts that carry the runway. A
window its own sessions will fill before its reset gets none while another
account carries the runway, and with none, the runway rule's fallback
weighs every account as before. Moving a running session there still
follows the runway, the window and the stranded rules.

Whether an account has a session window is read from each reading, account by
account, because a plan can drop it while others keep it (Claude's Ultra plan
for verified accounts; Max keeps it). The usage endpoint also leaves out a
window nothing has started, so for a plan known to have one
(`Account.planHasSessionWindow`, from `ProviderCapabilities.sessionWindowPlans`:
Claude's Pro, Max 5x and Team, Codex's Plus and Pro, every Kimi plan) a whole
reading with the long window alone carries the window unstarted
(`fillingUnstartedSessionWindow`, applied by `recordUsage`): the card shows it
at 0% as "5-hour window not started" (`sessionWindowDisplay`) and a warm-up
starts it, whether or not failover includes the account. For any other plan,
a reading with the long window and no session window means the account has
none: `merged(withNewer:clearingSession:)` drops a stored window, the card says
it has no session limit, `FailoverPlanner`, `QuotaSimulator` and `SessionPacer`
limit the account by its long window alone, and no warm-up probe runs for it.
No warm-up runs for an account that needs signing in or whose plan does not
include the CLI.
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

### Plans of different sizes

A provider's accounts can be on plans of different sizes: one percent of a
Claude Pro week is about a twentieth of the work of one percent of a Max 20x
week. Each account's percent is therefore converted through its own token
cost, `AppState.accountRatio` (session percent per million weighted tokens),
carried as `QuotaAccountState.percentPerMillion` and
`SessionPacer.Account.percentPerMillion`, whenever a rate or room moves to
or is compared with another account. The arithmetic itself (percent to
tokens and back, conversion between accounts, the room left in a session
and a long window, percent spent at a rate, run-out and latest-start times)
is `Allowance`'s, which the planner, the pacer, the simulator and the pace
outlook all count through:

- `FailoverPlanner.expectedBurn` and `carriedBurn` convert the moving work
  and its deviation into the destination's percent (`converted`), so
  `carries`, `destinationMinimum` and `tier`'s margins judge a destination
  by what the work costs there; 5% of a Max 20x week an hour is 100% of a
  Pro week. That covers the 5-hour window too: a session spending 10% of a
  session an hour on a Max 20x account spends 200% of a Pro account's
  5-hour window, which it would exhaust in half an hour. `carries`' burst
  allowance (a rate no window could carry for the hour needs room for
  `burstCarryShare` of one) is judged at the size of the account the work
  comes from, so a rate is no burst merely because the destination's plan
  is small.
- The switch's cost and the in-flight reserve are counted at the plan-wide
  cost (`Settings.referenceRatio`) and converted into the account they land
  on (`onAccount`).
- Destinations ordered by room (`plan`'s exhausted switch, most capacity
  first, `nextSwitch`'s preference for the account it projected) compare
  `tokenRoom`, headroom in tokens.
- Demand (`DemandForecast`) is recorded at the plan-wide size, and
  `QuotaSimulator` serves it at each account's own (`Account.scale`), so the
  week simulation behind balancing, the week outlook and the pace line adds
  like with like.
- `SessionPacer` compares accounts in tokens (`millions`): new-session
  weights, the destination a shed or stranded session takes, resumed
  sessions' placement, and whether a rebalancing move gains more than its
  rewrite. `poolRunOut` and the shared group's share were already counted
  in tokens; `sustainedShare` and the run-outs `rebalance` and `place`
  compare are times, which need no conversion.

An account with no measured cost is seeded from its plan size
(`ProviderCapabilities.planSizes`, keyed `<plan>:<tier>` or `<plan>`, read
by `Account.planSize` from the profile's plan and tier, or else the stored
plan and the credential's rate-limit tier; Claude: Max 20x 20, Max 5x 5,
Pro 1) by `TurnCostModel.ratio(for:sizes:)`:
a measured account's cost times its size over this one's (the geometric mean
over every such account), or, with none measured, the plan-wide cost scaled
from the median known size. A provider whose plan sizes are not listed, or an
account whose size is unknown (a Max plan without its tier), keeps the
plan-wide cost. The first measurement on the account replaces the seed, and
the Learning log records each change in where an account's cost comes from.

A few readings can mislead: a window that other use moved between two
readings can make a Max 5x account read like a Max 20x one, which would send
it four times the work it holds. A measured cost more than
`sizeDisagreement` (2) times off, either way, from what the account's size
makes of the other measured accounts' costs (their median, so one stray
account sets no expectation) is therefore blended toward that expectation,
in log terms, by how many of `trustedReadings` (10) readings it has learned
from (`TurnCostModel.accountReadings`), and stands alone after that
(`RatioSource.blendedWithPlanSize`). One reading whose sample strays more
than `strayReading` (4) times either way from the account's learned cost
starts that count again at one (`recordReading`): a single sample of 7.5%
per million took a Max 20x account trusted at 0.18% to 2.37%, over twice the
1.06% a Max 5x account at 4.25% makes of a window four times its size, and
the cost is then blended toward
the plan-size expectation again, as after a plan change, until
`trustedReadings` readings agree. Each measured cost is kept with the
plan it was measured on (`TurnCostModel.accountPlans`, the plan and the
rate-limit tier): once the account is on another plan, as an upgrade from
Pro to Max, which makes each percent five times the work, that cost is not
used, and the next reading forgets it and its readings
(`TurnCostModel.notePlan`, from `AppState.learnFromReading`), so the plan
size seeds the account until it is measured again. A tier learned after the
cost was is the same plan.

### Learning

| Model | Learns | Used for |
| --- | --- | --- |
| `QuotaTrend` | burn rate per window (median of recent intervals) and its spread, per account | projection while throttled, trigger timing, uncertainty |
| `TurnCostModel` | session percent per million weighted tokens, from router token counts and the readings that follow | expected request cost, switch cost |
| `DemandForecast` | weekly percent consumed per hour of the week | the simulator's demand |

Token weights follow relative price: context read from cache 0.1, cache writes
1.25, output 5. Learning is stored in `UserDefaults` under
`app.accountdock.learning.v1`.

## Pausing sessions

When every account is exhausted and no route target is configured, AccountDock
can pause sessions, so no request fails against a spent account. The user can
also pause them on demand from the main window's Sessions tab (**Pause all**),
for example before moving work off an account that failover excludes onto
accounts at their limits.

The Sessions tab (`SessionsView`, rows from `AppState.sessionRows`) lists every
running session of each provider with a pause gate or one-session slots, with
the account serving it, its state (`SessionRowState`, derived from the pause
files) and icon controls (`SessionControlButtons`, also in the account cards'
session lists): pin, pause or play, and move.

- **Pausing one session** (`AppState.pauseSession`, `AgentPauseGate.pauseOne`)
  with no pause in effect writes a pause of the user's that lists only that
  session, with `holdsNewTurns` false and `holdsListedNewTurns` true: the gate
  holds it at its next tool call and new turn and lets every other session's
  tool calls and turns pass. With a pause in effect, such as one at a limit,
  the pause holds the session again (`hold`). Either way the session is listed
  in the pause file's `chosen`: whatever ends the pause around it (capacity,
  a reset, a route, a rescoped limit pause) goes through `AppState.endPause`,
  which keeps the chosen sessions held as the user's own pause
  (`AgentPauseGate.narrowToChosen`); a route's narrowing keeps them too.
  **Resume all** releases them.
- **A pause the user took** (`PauseFile.heldByUser`: **Pause all**, which
  `pauseSessionsNow` writes, or sessions chosen one at a time) ends only by
  the user's hand: **Resume all** (`resumePausedAgentsNow`) or playing its
  sessions (`resumeSession`), the paths that call `endPause` with
  `keepingChosen` false. Every automatic path leaves it: `narrowToChosen`
  keeps it whole, `capacityEndsPause` is false for it (capacity returning
  and resets), `releaseSuspendedAgents` returns before it (pausing or
  monitoring turned off), `AgentPauseGate.narrow` and
  `holdSessionsTooLargeForRoute` leave "Pause all" alone, `suspendAgents`
  writes no pause at a limit over it (`limitPauseYields`), and paced resume,
  steps within headroom and `resumeSessionsLeftWaiting` skip the sessions it
  holds (`automaticallyReleasable`, `PauseFile.userHeld`). A session held
  both by the user and by a limit waits for the user. `resumeAsCapacityAllows`
  governs automatic pauses only.
- **Playing one session** is `AppState.resumeSession`
  (`AgentPauseGate.playOne`): the session goes on while the pause holds the
  others. When it was the last session held, the pause ends, as **Resume
  all** would end it.
- **Moving one session by hand** (`AppState.moveSession`, the same path as the
  requests interface's `moveSession`) moves a slot session with its slot, at
  once or by restarting, and restarts a session on the shared sign-in in a
  slot of its own on the destination (`prepareResumeSlot`). The session is
  then pinned there (`movePins`, settled by `settleMovePins` once its slot
  serves the destination), so failover and balancing leave it, unless
  balancing would place it there itself: `SessionMoveRules.balancingChoice`
  asks `SessionPacer.place` where the session would go among the accounts
  rebalancing weighs; a move onto an account failover excludes always
  pins. The move menu (`SessionMoveMenu`) lists every account with its
  room and whether the move pins it. A move by hand may go to any account
  that can serve the CLI: excluded, at its limit or near it is a warning
  (`SessionMoveMenu.warning`), and only an account that needs signing in or
  cannot serve the CLI (`Account.cliUnavailableReason`), or the one the
  session runs on, is refused (`SessionMoveRules.blocker`, which
  `moveSession` applies too). Each move is recorded.

A pause at a limit judges each session by the account it runs on
(`AppState.pauseScope`, built by `limitPauseScope`): a slot session by its
slot's account, a session on the shared sign-in by the active account. A
session waits only when its own account is at or near its limit (refused at
it, or reaching it within `suspensionLead`) and no move helps: a session on
the shared sign-in moves only with a failover switch, which `evaluate` found
none for before pausing; a slot session moves instead, through the slot-move
path, to an account `SessionPacer.place` picks among those with room that
carry one more typical session for the runway (`carriesNewSession`). A
session on an account with room never waits for another account's limit.
A pinned session never moves, so it waits instead once its own account is
past its failover threshold or at its limit (`AppState.pinnedHold`), whether
or not the active account is: every cycle `holdPinnedSessionsAtLimit` adds
it to the pause in effect, or writes a pause at a limit listing it alone
(`pinnedHoldPause`), and records "Paused X, pinned to Y, which reached its
threshold (or limit); it continues when Y has room." The same rule in
`pauseScope` lets it go on once its account has room, by a reset or a
reading, or once it is unpinned or moved; a pinned session the user plays
there runs on until the account has room again (`pinnedHoldsPlayed`). Such
a pause ends session by session, never because the active account has room
(`capacityEndsPause`), and neither paced resume nor steps within the active
account's headroom release a session pinned elsewhere.
The pause file lists exactly the sessions that wait, and each listed session
also waits at a new turn (`holdsListedNewTurns`); every new turn waits
(`holdsNewTurns`) only while no account has room
(`someAccountHasRoom`): none in the failover order, and none a slot
session runs on, such as an account outside the order the user pinned a
session to. With automatic failover off, a threshold or limit switch
`FailoverPlanner.plan` asks for is not made, and `evaluate` pauses at the
active account's limit by this same scope: the sessions on the shared
sign-in wait on it, while slot sessions stay with session balancing and
wait only for their own accounts. Every cycle,
`prunePausedSessions` narrows such a pause (`rescopeLimitPause`): a listed
session whose own account has room again, by a reset, a reading or its slot
moving to an account with room, goes on; when an account first has room
after all were at their limit, the pause stops holding every new turn and
lists the sessions whose own account is still at its limit; it ends when
none is left. It never ends whole because the active account has room
again (`capacityEndsPause` is false for every pause at a limit unless a
route target serves): its sessions go on account by account, each only
where a fresh reading shows room for it. A pause the user took, an account hold and a pause that
narrows a route keep their own rules. The pause file and the gate's markers
are all a pause is, so after a relaunch the same cycle picks the pause up.

The pause banner lists each held session (`AppState.pausedSessions`, read
from the gate's files alone: the listed sessions, those whose gate wrote a
`.waiting` marker, or every running one while the pause holds every new
turn, less those resumed), with the account it runs on and when that account
is expected to serve it again (`FailoverPlanner.availableAt`), and offers to
resume each one. The gate of every provider writes its markers under
`$HOME/Library/Application Support/AccountDock/Pause` named by the gate's
key and the session ID it reads from the hook's `session_id` (or
`sessionId`), the names the app reads; Codex's and Kimi Code's slots run in
the CLI's own home, so they read the same hooks.

Pausing is cooperative. A hook script (`accountdock-gate.sh`) runs after every
tool call (before every tool call for Kimi Code, whose post-tool hook does not
wait) and waits while the provider's pause file exists under
`~/Library/Application Support/AccountDock/Pause/`. The terminal stays attached
and the session shows a status message and terminal title while it waits.

- While the pause file sets `holdsNewTurns`, as a pause the user takes does
  and a pause at a limit does while no account has room, every session
  waits at its next tool call: also sessions not seen mid-turn when the pause
  began, and the subagents and workflow agents inside a session, which share
  its session ID. The sessions mid-turn at the start are listed for display
  and for the order steps are released in; a listed session leaves the list
  only when it ends.
- The same script runs on `UserPromptSubmit`, so any turn that starts waits
  there before its first request, including a subagent reporting back to its
  session or a scheduled agent waking up. The pause file stays until capacity
  returns, or, for a pause the user took, until the user resumes.
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
  sessions of a pause at a limit wait for **Resume all** or for capacity on
  an account in the failover order (the account active when the pause began
  only after a window reset); those of a pause the user took wait for the
  user alone.
- Every way out of a pause goes through `AppState.endPause`: capacity returned,
  a route target took the requests, or the user resumed; a route target that
  cannot take some sessions narrows the pause to them instead. The gate tells each
  resumed Claude Code agent to check its background work in all three cases.
- While the account still has some room, one step at a time is released through
  an `.allow` file, within the remaining headroom.
- A pause at a limit ends when a reading confirms capacity, or when the user
  chooses **Resume all**; a pause the user took only by the user's hand.
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

With pausing off, nothing is paused, but a slot session can still be left
idle by its CLI: Claude Code stops at a usage limit with a dialog (**Stop
and wait for limit to reset**, **Wait here, then continue automatically at
…**, **Add funds …**) or a footer counting down (`Continuing automatically
at … · esc to cancel`), and waits for the reset of the account it was
refused on even after AccountDock moved its slot to another account. With
the policy's **Resume sessions left waiting at a limit once their slot has
room** (`resumeSessionsLeftWaiting`, on by default; offered for providers
with slot isolation), each quota cycle looks at the slot sessions refused at
a limit (from their transcripts) within the last six hours whose slot now
serves another account that can serve them
(`AppState.leftWaitingCandidates`). For each one running in agterm whose
screen shows that wait (`ProviderSessionIsolation.screenWaitsAtLimit`, read
from the bottom lines so a transcript quoting it does not count),
`SessionTerminalActions.resumeWaitingAtLimit` types Escape
(`cancelWaitKey`), which takes the dialog's cancelling choice or cancels the
countdown, then a prompt telling the session to continue, once per refusal,
and records "Resumed X, which the CLI had left waiting for a reset, now
that its slot is on Y." A session whose screen shows no such wait, as one
mid-turn, is left alone; a slot AccountDock has not moved is never touched.

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
  soon takes more new sessions before its allowance is lost. A 5-hour
  window that resets before its limit starts again empty there and the
  rate carries on into the next one (`SessionPacer.refilled`): 64% an hour
  on a Max 5x window twelve minutes from its reset reaches the next
  window's limit 93 minutes after the reset and waits there three and a
  half hours, which counts as that limit; a wait of under a cache
  lifetime at the end of the next window does not. The accounts' joint
  run-out (`poolRunOut`) counts a whole window for every reset before it
  (`roomBy`), so bytrix's last 7% minutes from its reset counts the window
  after it, and failover's forecasts (`secondsUntilTrigger`,
  `secondsUntilExhaustion`) count no 5-hour crossing after the window's
  reset, so no switch is projected off a window the reset refills first.
- An account that would reach its limit and then wait there longer than its
  sessions' prompt cache lasts (the longest `cache_control` lifetime they
  sent, an hour when unknown) gives sessions up when moving them keeps the
  work running longer (`SessionPacer.ShedReason`): it reaches that limit
  more than a cache lifetime before the accounts together would have spent
  what they have (`poolRunOut`), or, for the account carrying the shared
  group while a switch is projected, before the group alone would take it
  to its limit or the switch. Over the days to a weekly reset any rate
  reaches a limit, so the wait alone would have every busy weekly-only
  account give sessions up. It gives up those relieving the most rate per
  cache rewrite first, until it no longer would. Sessions whose next turn
  comes soon go before one deep in a turn that began more than 15 minutes
  ago and is still sending (`SessionPacer.movable`), since a move applies
  only at a session's next turn. A session moves only to an account that,
  with the session's rate and the cost of writing its context into that
  account's cache, reaches no limit before its reset, or none until within
  an hour of the pool's run-out, and in either case none within the hour,
  by whichever of its windows binds first. Since that run-out counts the
  windows refilled on the way, a heavy session takes any one account to a
  limit long before it; with no such destination, one reaching no limit
  until within an hour of the source's own takes it, which serves it no
  shorter than staying would. The router moves it at its next turn
  (`RouterState.moves`). The event names the reason ("… while the other
  accounts still have room (together they last until …)").
- An account whose weekly allowance its session windows could not drain
  before its weekly reset even filled to the limit one after another
  (`SessionPacer.useBy`: its weekly room exceeds what its windows hold until
  that reset, `sessionCapacity`, by `minimumLeftover`; weekly balancing's
  latest start for it has passed) has free room: every percent its windows
  serve until the earlier of its session window's reset and its weekly reset
  is weekly allowance that would otherwise expire unused. Reaching its
  session window's limit is then the goal, not a run-out: `plan` sheds
  nothing from it for its whole allowance and moves none of its sessions to
  spend a remainder or a window, and `rebalance` neither moves a session off
  it nor takes its run-out for a bottleneck or reports it. Its room left at
  that time at its own rate (`freeRoom`) is the first destination of a
  session the shedding rule moves, the stranded placement (`place`) places or
  a rebalance moves, when the session's arrival and its rate until then, or
  for `newSessionRunway` when that is later, fit `windowFitShare` of that
  room (`fitsFreeRoom`) and it reaches no limit there within the hour: a
  session sized to the room, so a heavy one does not push the account's own
  sessions to its limit early. Once at its limit its sessions wait for a reset within
  their cache or move on, as from any limit. The 5-hour window is the cap:
  with 68% of a Max 5x week left 3 h 48 min before its weekly reset and 37%
  of its window used, the window resetting half an hour after the week, at
  most the window's 63% can be used before the week resets, about 8% of
  the week at eight windows to the week, of the 68% it shows; one session at 52M weighted tokens an hour
  fills it by 10:25 pm, and more sessions there would only fill it sooner.
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
- A session whose account is at its limit (refused at it) or within
  `suspensionLead` of it, and whose account resets at least a minute
  (`resetHoldMargin`) before the session's prompt cache expires (its last
  request plus its cache lifetime, an hour when unknown), **waits** on that
  account and continues there with its cache
  (`AppState.holdSessionsForImminentReset`, `cacheOutlastsReset`), with the
  policy's `waitForResetWithinCache` (on by default) and pausing at the
  limit, since the gate is what holds it. It runs every quota cycle before
  the slots are served, for every gated provider: a slot session waits on its
  slot's account, a session the router serves from its pool on the account
  serving it (a reset within `RouterLogic.maximumHold` left to the router),
  and the sessions on the shared sign-in on the active account, all of them
  or none (`sharedSignInWaits`: those whose caches outlast the reset hold at
  least half the group's context), while failover's plan stays
  (`FailoverPlanner.Settings.sharedSignInWaitsUntil`,
  `.stay(.waitingForResetWithCache)`). The reset is
  `FailoverPlanner.heldAvailableAt`, which after a refusal takes the fuller
  window's. Each wait (`AppState.SessionWait`, in `sessionWaits`) is one more
  session a pause at a limit lists: it joins the pause in effect or a pause
  listing it (`pinnedHoldPause`), at its next tool call and new turn, and
  `limitPauseScope` keeps it held, placing it nowhere, until its account
  serves again (`servesAgain`: a fresh reading with room, no refusal since),
  or `accountHoldGrace` after the reset with no reading showing it.
  Meanwhile `serveSessionSlots` keeps its slot there (`slotChoice`'s
  `waitsOn`), `paced` and the automatic rebalance leave it, the stranded
  placement skips it, `admitPausedSessions` lets it go only where it is, and
  steps within the active account's headroom go to no session waiting on
  another account. Only sessions with at least `heldCacheMinimumContext`
  tokens of context wait: a smaller one rewrites its context elsewhere for
  less than its idle wait costs. A session the user plays goes on, and its
  wait no longer holds it (`SessionWait.played`). The event reads "Holding
  session X on hexorda until its reset at 3:09 pm: sooner than its cache
  expires, so it keeps its cache." A pause file that names one account
  (`PauseFile.account`) ends at that account's reset (`endAccountHoldIfDue`).
- Why a small plan's window with room takes no running session is said
  (`AppState.noteLaneShortfalls`, `SessionPacer.laneShortfall`, kept in
  `laneNotes`): under the provider on the Sessions page and in the rebalance
  preview, as "voltrix: no running session fits; the lightest active one
  (session X) would use its window in 40 min.", or that none elsewhere has
  used anything in its last hour, that the lightest one's rewrite outweighs
  its use, that the accounts carrying the work still have room until their
  resets, or that its reading is too old. Before those, each account with
  free room (`useBy`), the soonest first, is described
  (`AppState.useByNotes`, `useByNote`): how much of its week resets when,
  what its 5-hour window lets it use before then, and which sessions use it
  and when they fill it, or that nothing does and new sessions go there
  first: "bytrix: 68% of its week resets on Tue 1:00 am; its 5-hour window
  caps what can be used before then at 63%; session 8c64c5f8 in ~/ORBTR is
  using it, filling it by 10:25 pm."
- An idle account that could take sessions stays a destination
  (`AppState.readIdleDestinationIfDue`, `idleDestinationDue`): while
  sessions are served from several accounts, each quota cycle reads one
  included, signed-in account serving no session whose last reading shows
  room and is older than `FailoverPlanner.idleFreshness` (15 minutes), the
  one read longest ago first, at the priority of a passed reset's
  confirmation within the provider's request budget; a reading not taken is
  tried again after `idleFreshness`. Nothing else reads an account no session
  uses, and a reading too old keeps it out of the pacer's moves (`stale`).
- New sessions go to accounts by unused rate, the pool weight times the
  rate the account can still add without reaching its limit; with none
  left anywhere, by the share of the time to its reset each account lasts
  at its rate (`SessionPacer.sustainedShare`), the shared group's share
  included. Free room comes first: while an account has room left at its
  use-by time that one more typical session fits (`fitsFreeRoom`) and
  carries it for `newSessionRunway`, new sessions go only to such accounts,
  by that room's tokens per hour until then. Where the weights measure room
  to a horizon every account shares (the pool's run-out while the shared
  group is projected to move, the first carrier's reset while the small
  plans' windows are worth spending), an account's room counts at most at
  its even rate (`SessionPacer.evenRate`): its room until it is lost (its
  use-by time, else its weekly reset, the windows refilled on the way) over
  the time until then, which orders accounts as weekly balancing's latest
  start does. A weekly-only account with 11% of a Max 20x week left and six
  days to go counts 1M tokens an hour, not the 2.6M its room until the
  first carrier's reset would give it, beside a Pro window's 2.6M and a
  Max 20x week resetting the next night that needs 59M.
- An account sessions run on whose reading is older than its sessions'
  latest request, and older than ten minutes, stays in the pool for up to
  an hour with its weight scaled by ten minutes over the reading's age
  (`FailoverPlanner.poolReadingConfidence`); its tier is judged on the
  reading grown by its learned burn.
- A slot session whose account can no longer serve it goes where the pool
  lasts longest with it (`SessionPacer.place`, through
  `AppState.strandedPlacements`): one at a time, largest rate first, to the
  account that leaves the earliest run-out among every pool account that
  can serve it (`AppState.strandedDestinations`), whatever its weight for
  new sessions, as **Rebalance sessions now** measures it. Each destination
  is charged the whole cache write of the session's arrival
  (`SessionPacer.arrivalCost`: its context at 2 a token for the one-hour
  cache, 1.25 for the five-minute one), not only what the move adds over
  staying. A session is known by its lifecycle record, and also, for a CLI
  that keeps its own registry of the session each process holds (Claude
  Code's `~/.claude/sessions/<pid>.json`, `CLISessionRegistry`,
  `ProviderCapabilities.cliSessionRegistry`), by that registry:
  `AgentSessions.live` keeps a session whose record is older than
  `liveLifetime` (12 hours, as for one quiet at its prompt overnight) while
  the registry names its process with it, and lists a registered process no
  live record covers as the session the registry names, so a pause lists
  it and the plans name it by its ID. Only a slot read by a process that
  may hold a session is a run (`slotRunDirectories`): one the registry
  lists, or, for a CLI that keeps none, one of the CLI's own processes. A
  helper that outlived the session that started it (an MCP server, a
  script) and a CLI the registry does not list, such as `claude --resume`
  waiting at a prompt before its session starts, send no request and are
  never planned or charged. A run whose process left no session record is
  placed by its slot's
  path at `defaultSessionRate`, weighed and charged in the cycle's ledger
  with the sessions; one admission leaves waiting is kept on its account
  by its slot (`admissionHeldRuns`, `slotChoice`'s `heldOn`) and never
  listed in a pause, which knows no session of it. The events and plans
  name it by the folder its process runs in ("a run in ~/ORBTR",
  `AppState.unrecordedRunName`, from the `PWD` `refreshSlotProcesses`
  reads, `slotFolders`), never by its slot's path. The sessions an exhausted account, or
  a small plan's filled session window, gives up spread over the accounts
  with room by how long each then lasts, instead of all going to the account
  with the largest pool weight: a session that must leave is served rather
  than refused, even where it lasts less than an hour.
- While capacity is scarce, with pausing at the limit, a lane with room
  does not take every such session (`SessionPacer.admitToLanes`, through
  `strandedPlacements` and `limitPauseScope`): each lane's room is what it has
  left by its reset, or by `newSessionRunway` when the reset is later
  (`spare`), beside the sessions it runs and the shared group's share; a
  session fits when its arrival's cache rewrite (`arrivalCost`) plus its rate
  until that horizon is within `windowFitShare` of the room still left, and
  each admitted session's rewrite and rate are charged to the lane before the
  next is weighed. One pair at a time, it admits the session that runs
  longest: first one whose whole use until the lane's reset fits, then one
  whose own account resets later than its cache lasts (`bindingReset`), then
  the lane whose weekly allowance its own rate would leave unused soonest, as
  weekly balancing orders accounts, then the longest run. When every session
  fits (an account with ample room among the lanes), `place` spreads them as
  above. The others wait on their own account
  (`SessionWait.Reason.awaitingLane`, `noteLaneAdmission`), listed in the
  pause, until it serves again or a later cycle admits them, and the event
  reads "Session balancing admitted 2 of 9 waiting session(s) to cybrio's
  fresh window: they fit until its reset at 8:29 pm; 7 wait for their own
  accounts."
- Every rule that sends a session to an account within one quota cycle
  charges that account in one ledger (`LaneLedger`, kept per provider in
  `AppState.laneLedgers` and started afresh by `runQuotaCycle`): each
  session once, at the weighted tokens per hour it is expected to use from
  when it starts there (now for a placement, a move or a release from a
  pause; the account's reset for a planned wait or a session a wait holds
  there, `chargeHeldWaits`) plus its arrival's cache rewrite in that
  account's cost. A session a pause or a wait holds is expected to use
  what it used over the hour before it was held (`AppState.heldRate`, from
  `heldSince` and `SessionRates.heldDemand`, in `slotRebalanceSessions`),
  not the near nothing it sends while held: weighed so, ten sessions held
  for two hours each look like a few thousand tokens an hour, all fit the
  first fresh Max 5x window, go on there together and are refused at its
  limit minutes later. At each reset, after the reading that confirms it,
  the lane takes only the held sessions it carries for the hour, and the
  rest stay held for their own accounts or the next lane. That demand is
  at least what the session used while it worked
  (`SessionRates.workingDemand`: the hour's tokens over the time it
  worked, each gap of more than `runGap` between its requests left out, at
  least `runGap`), so a session held two minutes into a burst after an hour
  of waiting on its user counts at the burst's rate, not at the burst
  spread over the hour. A session the stranded placement, the slot path's
  fallback or a pause at a limit sends to another account counts there at
  least at its working rate before its last request
  (`SessionRates.arrivalRate`): quiet for hours it uses nothing where it
  is, but where it is sent it works at that rate once its user speaks
  again, so two such sessions are not both sent to one window their work
  empties within the hour. Lane admission and the stranded placement count the
  charges started by now beside each lane's own sessions; the held-session
  plans, the slot path's fallback (`ledgerFallback`) and the sessions a
  pause releases test the destination with `CapacityOutlook.carries`: from
  when the session starts there until an hour later, everything charged
  there and the session itself, grown by 1/`windowFitShare`, fits the room
  the account has then, its resets refilling it on the way. An account at
  its limit carries nothing before the reset that frees it.
- No session is sent, moved or released onto an account on a belief of
  room (`AppState.freshForArrivals`): the account must have been read
  within `arrivalReadingAge` (5 minutes), with no passed reset still
  unconfirmed, and must have refused no request since with a reset still
  to come (`refusedUntilReset`: a refusal keeps its account at its limit
  until the reset its words state, `refusalHolds`, whatever older readings
  show; one of a session whose model has an allowance of its own there is
  left to `recordedLimitRefusal`). That holds for the stranded placement's
  destinations, the slot path's fallback, `limitPauseScope`'s destinations
  and `admitPausedSessions`' accounts. While sessions wait for room,
  `readIdleDestinationIfDue` keeps every account showing room, those
  serving sessions included, read within that age. A pause at a limit
  releases the sessions it holds only as far as the ledger lets them
  (`releaseFits`, from `rescopeLimitPause` through `limitPauseScope`'s
  `holding`): each goes on where its account, read fresh, carries its rate
  before it was held for the hour beside the sessions running there and
  everything the cycle already sent or released there, the other held
  sessions competing rather than loading it, and is charged once released;
  one no window holds for the hour goes on alone on an account nothing
  else uses. "The account each paused session runs on has room again;
  resumed N session(s) and ended the pause." is recorded only once every
  held session has gone on so.
- Each session admission leaves waiting gets a plan (`HeldSessionPlan`,
  through `AppState.planHeldSessions`, kept in `heldSessionPlans`), and they
  are planned together (`HeldSessionPlan.planTogether`), the heaviest first,
  each against the ledger, which then charges its lane: it waits for the
  earliest lane, the account whose 5-hour window, week or limit resets
  first and carries an hour of it beside the sessions there and everything
  already planned onto it, its own account included and charged no
  rewrite. A lane's fresh window is so planned only as full as it holds for
  the hour; the next sessions go to the next lane by its reset, and a
  session no lane carries for an hour within a 5-hour window of its own
  account's reset waits for its own account, charged there from that
  reset. Each lane window's set stays steady from cycle to cycle: the
  sessions the last cycle planned to wait are planned first, window by
  window in the order of their resets, so each keeps its lane while it
  still fits there, then the rest by rate; the plan made heaviest first
  replaces that only when, at the first window whose set differs, it puts
  at least `HeldSessionPlan.replanMargin` (10%) more of that window to work
  for the hour (an hour of each session's rate less its arrival's
  rewrite, `prefersReplan`). A planned session that goes leaves its room
  to the next by rate, and every tie keeps the steady plan. The summary
  event records the plan by its resets to the nearest five minutes
  (`summaryMinute`), so a reset reported on either side of a minute does
  not record it again. With every account at its limit, admission has no
  lane and every stranded session is planned so. It moves now instead to a
  lane with room only when that serves more work until an hour past that
  reset (`CapacityOutlook.servedAlone`, counting the lane's ledger charges:
  what the session adds there, less what the sessions already on it lose
  once it fills the lane early, less its rewrite), and only when its own
  account resets later than its cache lasts; a tie waits. A planned wait
  whose reset has come is placed on its lane once that lane is a
  destination (`HeldSessionPlan.due`: a reading confirms the reset) and
  still carries it beside what the cycle sent there, and stands for
  `accountHoldGrace` until one does. The plan is the session's row note
  ("resumes on fluxon about 12:50 am"); a move is an event when it changes,
  and the waits one event while it says the same
  (`HeldSessionPlan.summary`): "At 12:50 am fluxon's fresh window takes
  platform-execution and continues-field (≈ 60 min of its window); 5 others
  wait for hexorda at 1:10 am, bytrix and cybrio at 1:30 am." While admission keeps a session on its account, played or not,
  `slotChoice`'s path for an account that can no longer serve keeps it there
  (`heldOn`, from `admissionHolds`) rather than sending it to the pool's
  `fallback`; admission's placement or the user's own move takes it
  elsewhere. Any other session on such an account goes to the first account
  by pool weight that can serve it and, by the ledger, carries it for the
  hour (`AppState.ledgerFallback`), which is then charged with it, and
  stays where it is when none does, held by the pause at the limit. No
  automatic rule moves a slot onto an account that cannot serve it
  (`slotChoice` passes over such a placement, fallback or balancing move,
  and a pacer move is taken only to an account that can serve), so the
  sessions an account gives up go one at a time where the ledger has room
  for each, never all at once to another account at its limit; only the
  user's own move goes anywhere.
- An account a threshold switch left with room still on it drains
  (`AppState.drainingAccounts`): above its thresholds it keeps a pool weight
  of `drainingShare` (0.5) instead of none, or `drainingPreferred` (2) when
  every other account has under `lowWeeklyRoom` (20%) of its week left, and
  pacing moves none of its sessions off it. The runway rule still applies,
  so it takes no new session that could not last `newSessionRunway` there:
  in the pacer's weights, and before pacing in `buildPool`, where any
  account that could not carry one more session of the running sessions'
  typical rate for that hour beside its own rate
  (`AppState.carriesNewSession`; a 5-hour window resetting within the hour
  needs the room until its reset and a whole window after it) has weight 0
  while another could, a
  draining one at `drainingPreferred` included, unless its session window
  would otherwise leave room unused at its reset (`AppState.windowShare`,
  under Balancing above). The drain ends when a reading or a refusal shows its limit, when it is
  active again, or a session window after the switch.
- A session that starts a turn after its cache has expired is placed again
  like a new session (`RouterState.cacheAwareSessions`), since moving it
  loses nothing.
- With one-session slots, the sessions on the shared sign-in (outside a
  slot, background workers included) all run on the active account and move
  together whenever it changes, so the pacer takes them as one group
  (`SessionPacer.SharedGroup`, built by `AppState.sharedGroup`) and never
  moves them: their rate over their last hour, context and models. The
  group counts on the active account until the switch failover projects
  (`FailoverPlanner.nextSwitch`, which asks `plan` itself as of the moment
  the active account's burn crosses a threshold, or failing a switch then,
  reaches its limit), and on the account it would switch to from then until
  that account's resets, with the cache rewrite of the group's context on
  arrival (`SessionPacer.shares`). Pool weights, model weights, the runway
  rule, moves and **Rebalance sessions now** all see that load, so no slot
  session is placed or moved onto room the group will need. With failover
  off for the provider or the active account locked, the group stays on the
  active account for the whole horizon. The active account's readings
  already include the group's rate, which its share counts instead.
  `plan` switches only to a destination that carries the moving work
  (`FailoverPlanner.carries`, above), so the projected account is the one
  the switch will pick. The account projected last time
  (`AppState.sharedGroupDestination`) stays projected while `plan` would
  still switch to it, unless the account `plan`
  prefers has twice its headroom (`projectionPreference`), so the room the
  pacer keeps does not move between accounts from cycle to cycle.
  While the group is projected to move, new sessions go by the room each
  account has left (`SessionPacer.spare`) at the pool's run-out
  (`poolRunOut`: when the accounts taking sessions and the group's, at
  their rates and the group's, would together have spent what they have,
  counted in tokens): the group spends the active account's room until the
  switch and the next account's after it, but not past that run-out.
  Measured to each account's reset instead, the group's rate over the
  days to a weekly reset would exceed the next account's room and leave
  it no weight, while the active account, which the group leaves at the
  switch, would look free, and new sessions placed there bring the switch
  closer. When the
  group is projected to move, an event and the rebalance preview say so
  ("AccountDock keeps room on B for the 4 sessions on the shared sign-in,
  which move there at about 3:40 pm.").

A session whose model's own allowance is spent on every account stays where
it is and is refused. With the policy's `noRoomModelFallback` (off by
default, one of the provider's `sessionModelChoices`; none for a CLI that
cannot change model within a session), `AppState.applyModelFallbacks` types
`/model <id>` and Enter into the session's terminal once its turn has ended
(`AgentSession.isIdle`, never mid-turn), through `SessionTerminalInput`:
`AgtermTerminalInput` finds the agterm session in the process's
`AGTERM_SESSION_ID` and passes the text to `agtermctl session type --stdin`,
each call limited to 15 seconds. The switch, or why it could not be made, is
recorded as an event.

Sessions served from one-session slots start through the launcher, which
`SessionSlots.installLauncher` puts first on `PATH` from `~/.zshenv`, read by
every zsh, and again last in `~/.zshrc`, since the login files' `path_helper`
and Homebrew's `shellenv` put the CLI's own directory ahead of it in a
terminal's shell. A run started by full path, from an IDE or the desktop app,
or before the pool was ready reads no slot (no `slotDirectoryByProcess`
entry): `AppState.noteUnisolatedSessions` lists such sessions on the usage
tab ("N sessions not isolated") and records each once. At the user's request
only, one idle in agterm (its last event `Stop`) is restarted in its own slot:
`/exit`, Enter, then the isolation's resume command (`claude --resume <id>`),
Enter, typed into its agterm session, so the resumed run goes through the
launcher. A session mid-turn or outside agterm is never typed into; the list
says why. Its screen is read first (`SessionTerminalInput.screenText`,
`agtermctl session text`): a footer that reports work still running, such as
Claude Code's `· 1 shell` for a command it started directly, leaves it alone,
and so does the CLI's exit question about such work ("Background work is
running"), which is answered with Escape (stay), never Enter, whose first
choice stops the work. A background session's restart reads its attach
client's screen the same way before stopping it.

A CLI with a background-session service (`backgroundSessions`; Claude
Code's `claude --bg`, `claude attach <id>`, `claude stop <id>`) runs each
background session in worker processes its supervisor starts with its own
environment, so a worker never passes through the launcher and reads the
shared sign-in. `BackgroundSessionProcesses` reads them from the same process
list as the slots (`refreshSlotProcesses`): a worker is an unisolated session
on the shared sign-in, listed as a background session; a process running one
of the service's commands (the attach client, the supervisor, `stop`, `logs`,
`rm`, `agents`) or a `--bg` launch is no session. The launcher runs those
unchanged, as it runs the sign-in commands, and such a process is left out of
`slotDirectoryByProcess`, so a slot an attach client reads is released
like any slot no process reads, and no session record it left is counted. Restarting a background session in its own slot
waits until it is idle by every sign: its last event `Stop`,
its transcript and its subagents' quiet for two minutes, and no shell under
its worker, as its Bash tool starts; then it runs `claude stop <id>` and
types `claude --resume <id>` and Enter into the agterm tab of its attach
client, so the resumed run goes through the launcher. A background session
refused at a usage limit since its last served request counts as idle and
quiet, since its turns all fail; the shell under its worker and its attach
client's footer still hold it.

A worker keeps the token it read in memory and does not read the shared
sign-in again when signalled, so a background session on an account that can
no longer serve it (refused at its limit there, or flagged by the audit as
holding that account's token while the account is at its limit) is stuck:
`handleStuckBackgroundSessions` offers its restart once in the events and
marks it in the usage tab's list of unisolated sessions, and with **Restart
stuck background sessions in their own slot** (Settings → Failover, off by
default) makes the restart itself, at most once every ten minutes per
session. The audit's `signalSessions` keeps such a session flagged and names
its restart rather than signalling it.


**Rebalance sessions now** (the Sessions and usage tabs' provider headings, for a
provider whose sessions run in one-session slots; also the requests action
`{"action":"rebalance","provider":…,"apply":true|false}`) places the running
slot sessions so the first account to reach a limit does so as late as
possible (`SessionPacer.rebalance`). Each session counts at its rate over
its last hour (`AppState.rebalanceRate`: `defaultSessionRate` with no
history, and what it uses now, near nothing, once it has used nothing over
its last hour, so no idle session is moved to make the others last longer) against every
window and its model's own allowance, and each account also carries the use
its readings show beyond its sessions and the shared group
(`SessionPacer.unseenBurn`), which stays wherever the sessions go: the rate
the pacer counts for an account is the larger of its readings' rate and its
sessions' total, and with this the preview's run-out is measured at the
same rate. A local search moves, one at a time, a
session off the account that runs out first to the destination that leaves
the latest earliest run-out, charging the destination the session's cache
rewrite; a move is made only when the hours it gains at that account's burn
are worth more than the rewrite, a session moves at most once, and a session
mid-turn never. An account that runs out first but no single move helps (one
at its limit whose readings still rise with the sessions on it, or one whose
only sessions are mid-turn) is settled: it stays as it is, takes no session,
and the search goes on with the account that runs out next, so such an
account does not end the search before the accounts the sessions crowd. The
run-outs reported then leave out the accounts settled before the first move.
The result never runs out earlier than before and every move pays for itself;
it is a local optimum, not always the best assignment. A run-out is measured
with the pacer's outlook, the window after a reset included (`refilled`), so
64% an hour on a Max 5x window twenty minutes from its reset runs out 93
minutes into the next window, and the search puts no such session there for
the shedding rule to give up minutes later. A 5-hour limit reached within the
router's hold of its reset (`RouterLogic.maximumHold`) is no run-out
(`SessionPacer.runOutOutlook`): the account serves on from the reset, so a
window filling a minute before its reset is not reported as "the first
account runs out" at that reset.
Excluded accounts, those needing sign-in and those at their limit are no
destination. A movable session on an account that is no destination, one at
its limit or refusing it, gains from any room however short: before the
search, each goes where `SessionPacer.place` puts it, spread over the
destinations as the stranded placement spreads them, and is reported as
moved off an account that cannot serve it (`Rebalance.unblocked`). While the
windows are worth spending (`windowsWorthSpending`, for the accounts
`remainderSpending` offers), the local search is not run and the movable
sessions are placed on those windows by the pacer's own rule
(`spendWindows`). The moves go through `requestedSlotMoves`, so each is
recorded. With **Rebalance automatically** (off by default) the quota cycle
makes the same moves at most once per `balanceMoveInterval`, and only when
they move a session off an account that cannot serve it or into a session
window, or the first account then runs out more than an hour later.

A move writes the session's whole context into its new account's cache,
which pays off only while the session stays for that cache's lifetime. A
slot session whose slot moved, by any rule or by hand, is therefore within
its **hold** for its cache's lifetime, at least an hour
(`AppState.moveHold`, `slotSessionsWithinHold`, from
`slotDirectoryMovedAt`): no automatic rule moves it again, neither the
pacer's shedding, remainder and window rules (`SessionPacer.plan`'s `held`,
and `serveSessionSlots`, which applies a pacer move only after the hold) nor
the automatic rebalance (`rebalance`'s `held`). Its account refusing it or
reaching its limit still moves it, through the stranded placement or as a
rebalance's blocked session, and a move the user asks for is never held. An
account whose only sessions that could relieve it are within their hold
gives none up (`SessionPacer.plan`): their move was planned against the same
outlook, so it records no event saying it gives sessions up minutes after
it took them.
A move a hold stops is recorded once per hold (`Plan.heldBack`,
`Rebalance.heldBack`, `AppState.noteHeldMoves`): "Kept session X on hexorda
although pacing would move it to Backup: it moved there at 11:42 am, and
moving it again before 12:42 pm would write its cache a second time before
the first has paid off. It moves sooner only if hexorda refuses it or
reaches its limit."

A slot session can be **pinned** to its subscription (`SessionPins`, kept by
session ID under `app.accountdock.failover.pins`, so `--resume` of the same
session is pinned too and resumes on the pinned account; a pin goes when its
session's record is archived or removed). Nothing automatic moves a pinned
session: `serveSessionSlots` keeps its slot on the pinned account even when
that account cannot serve it (`AppState.slotChoice`; recorded once per run
at the limit), drops requested moves for it, and neither `SessionPacer.plan`
(`fixed`), `rebalance` (not movable, like a session mid-turn, permanently)
nor `applyModelFallbacks` touches it, though its rate counts as load on its
account. A session on the shared sign-in cannot be pinned; its row offers a
restart into its own slot first. A session opened from a tile's session
button is pinned there unless the menu's **Keep here** is unchecked or
Option is held while choosing; the slot is pinned first and the session
reading it takes the pin. Clicking an account card's session count ("4
sessions · 1 pinned") lists its sessions with the Sessions tab's controls
(lock, pause or play, move); a pinned session refused at its account's limit
shows "pinned · refused at limit" with **Switch model**, and its move menu
unpins and moves it. The Sessions tab shows every session's pin, and the
requests interface takes `{"action":"pin"|"unpin","session":…}`;
`moveSession` refuses a pinned session.

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

### Outlook

`CapacityOutlook.project` answers, for the Sessions page and the usage tab
(`CapacityOutlookView`), how long a provider's sessions run at their current
rates and when they run again. `AppState.capacityOutlook` builds its inputs
and keeps the result until the next usage refresh or for a minute
(`capacityOutlookLifetime`), so a redraw does not project again: every account
of the provider as `pacerAccount` sees it, with its `sessionPerWeekly` to size
a new week, taking part unless excluded, needing sign-in or ineligible, and
blocked until its `bindingReset` when at its limit; and every live session at
`SessionPacer.lightRate`, a session a limit holds at `SessionRates.heldDemand`
and one the user holds at nothing. Nil until the router has measured a
session's rate.

The projection steps forward five minutes at a time, and to every reset in
between. At each step a passed 5-hour window starts again empty, a passed week
starts again full a week on, and the step's demand is served from the
accounts with room (`roomBy` at that moment) in the order session balancing
spends them: first the accounts whose week would expire unused even with
every window filled (`SessionPacer.useBy`), soonest use-by time first, each up
to its window's limit, then the rest by weekly balancing's latest start
(`Allowance.latestStart`). Within a step the served part runs first, so
the moment the last room goes is exact to the step's share. The first step
with demand left over is the pause (`allPausedAt`); after it, a running stretch
of at least `resumeRun` is the resume, named by the refill that frees the most
tokens at its start, and shorter ones are bursts. It stops shortly after the
resume, or after seven days. The what-if runs it again without the heaviest
session. Moves' cache rewrites and use the router does not see are not
counted.

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

`RouterLogic` holds every decision as pure functions (`planMessages`,
`poolAttempts`, `refusalAction`, `replyVerdict`, `preparedBody`,
`bridgeCredentials`), which the tests cover directly. `RouterService`
forwards and reports on a `RouterEnvironment` (directory and port); the
launchd router runs one on the standard environment, and the tests run one
on a temporary directory against local fake upstreams.

Events reach the app through `RouterEventLog`: each carries a sequence and
is appended to segment files in `Router/events/`; the app reads whole lines
from its cursor and writes the last sequence it applied to
`events/acknowledged`, and the router removes a segment only once every
event in it is acknowledged, or past 32 MB while the app is away. A slow
app, a rotation or a restart of either side loses nothing.

Both sides size a session by `SessionSizing`: its last measured context
(the request's size at four bytes a token only before any measurement), a
cache lifetime of an hour when none was asked for, and a move costing its
context's rewrite at 1.15 weighted tokens per token, so the router routes
exactly the sessions the app does not hold.

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
  reach the router. The key is also set in every home AccountDock manages
  for a Codex account (`RequestHoldSupport.managedHomes`), and a slot
  session, whose provider names its own base URL, is started with the
  router's whenever Codex's config points there. A request signed with an
  API key goes to `https://api.openai.com/v1` instead of the ChatGPT
  endpoint when the key was absent (`ProviderPassthrough.clientAuth`).
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
  accounts, and only for `POST /responses` and `POST /responses/compact`;
  every other path goes upstream. A compaction is answered whole: the
  backend summarises the conversation and the reply holds the user's newest
  messages and the summary, or, when the backend fails, the provider
  compacts.
- **Claude as the target.** `RouteTarget.claude` (offered only to a bridged
  provider, so Claude Code's own usage keeps its models) sends Anthropic's
  Messages API the pool accounts' sign-in tokens while the router has a
  Claude pool, a refusal at an account's limit going to the next, and the
  active Claude account's otherwise. Its dialect leaves out sampling and
  forced tool use, turns Codex's reasoning effort into `output_config.effort`,
  and returns Claude's thinking to it inside Codex's reasoning items.
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

The session hooks and the pause gate are written by one editor,
`HookConfigEditor`, with an adapter per file format: `JSONHookFile` for
Claude Code's `settings.json` and Codex's `hooks.json`, `TOMLHookConfig` for
Kimi Code's `config.toml`. Each hook carries a marker in its command or table
header. Installing replaces an event's marked hooks with one; removing deletes
them, and an event left with no hooks. A JSON edit adds a group after the
event's last one, in the file's own indentation, and removes one with the
separator before it, so every other byte of the file is kept and an edit that
changes nothing leaves the file untouched; a file that is empty, not a JSON
object or changed while being edited is never replaced.
`HookConfigEditorTests` holds the exact text each edit leaves.


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
| `~/Library/Logs/AccountDock-credentials.jsonl` | Credential audit trail, JSON Lines, owner-only, rotated at 20 MB keeping `.1`–`.3` |
| `~/Library/Logs/AccountDock-credentials-owners.json` | Token fingerprint → owner map the audit learned (obfuscated email, account ID) |
| `UserDefaults` `app.accountdock.mac` | Accounts, usage snapshots, failover settings and runtime, learning |

The app's files in `~/Library/Logs` take their directory from `AppLogs`. While
XCTest hosts the app it is `AccountDock-logs-tests-<pid>` under the temporary
directory instead, so a test run never writes the logs, the failover history or
the audit trail a person reads.


## Costs

Costs are computed locally from session logs: Claude Code's JSONL transcripts,
Codex rollouts and Kimi Code sessions, priced from `litellm-pricing.json`.
Codex rollouts are read from every home a Codex session writes to: `~/.codex`,
which its slots' sessions share, and each account's managed home; a rollout
found in several homes is counted once, the longest copy standing
(`UsageIndex.codexRollouts`). Claude Code turns the router served from a route target name the target's
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
