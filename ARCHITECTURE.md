# AccountDock Architecture

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

## Keychain Token Storage

AccountDock manages two sets of keychain entries:

```
macOS Keychain
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│  ┌─ Claude CLI owns this entry ─────────────────────────┐   │
│  │  Service:  "Claude Code-credentials"                  │   │
│  │  Account:  "<OS username>"  (e.g. "joey")             │   │
│  │  Password: <Active OAuth Token JSON>                  │   │
│  │                                                       │   │
│  │  Claude CLI reads/writes this to authenticate.        │   │
│  │  AccountDock accesses it via `security` CLI tool       │   │
│  │  (NOT Security framework) to avoid repeated password  │   │
│  │  prompts. User clicks "Always Allow" once.            │   │
│  └───────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─ AccountDock owns these entries ──────────────────────┐   │
│  │  Service:  "com.accountdock.tokens"                    │   │
│  │  Account:  "<Account-A UUID>"                         │   │
│  │  Password: <Account A's backed-up OAuth Token JSON>   │   │
│  │                                                       │   │
│  │  Service:  "com.accountdock.tokens"                    │   │
│  │  Account:  "<Account-B UUID>"                         │   │
│  │  Password: <Account B's backed-up OAuth Token JSON>   │   │
│  │                                                       │   │
│  │  Also accessed via `security` CLI — during dev builds │   │
│  │  code signature changes each time, so the Security    │   │
│  │  framework would prompt repeatedly.                   │   │
│  └───────────────────────────────────────────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Token JSON Format

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
- This lack of embedded identity is why AccountDock must verify CLI state before backing up tokens (see "Token Corruption Prevention" below)

### Token Corruption Prevention

A critical invariant: each account's backup token must belong to that account.
Since the token JSON contains no email/identity, AccountDock cannot verify ownership
from the token alone. To prevent saving the wrong token under the wrong account:

1. **Before backup**: always call `claude auth status` and verify the email matches
   the account we're about to back up for
2. **After switch**: verify `claude auth status` returns the target account's email,
   not just `loggedIn: true`
3. **Passive diagnostics**: on every refresh, extract token fingerprints (last 8 chars
   of accessToken) for all backups and the live token, and log warnings if:
   - Two different accounts share the same fingerprint (duplicate/corrupted backup)
   - The live token doesn't match the active account's backup (state desync)

---

## `claude auth login` — OAuth Flow

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

---

## Account Switching (A → B) — Complete Token Flow

**Precondition:** App has Account-A (active) and Account-B. User clicks "Switch" on B.

Token notation: `T-A` = Account A's OAuth token, `T-B` = Account B's OAuth token.
Fingerprint notation: `fp(T-X)` = last 8 chars of accessToken in T-X.

```
                                    ┌─ Keychain State ─────────────────────────┐
                                    │ LIVE: "Claude Code-credentials" = T-A    │
                                    │ Backup UUID-A: T-A                       │
                                    │ Backup UUID-B: T-B                       │
                                    └──────────────────────────────────────────┘

Step 0: PRE-CHECK — read backup fingerprints (keychain only, no CLI call)

    Read Backup UUID-A → fp(T-A)
    Read Backup UUID-B → fp(T-B)

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if fp(T-A) == fp(T-B):                                                 │
    │   → ABORT: "Both accounts have the same token."                        │
    │   → Show error: "Use re-authenticate (↻) to fix."                     │
    │   → This catches the corruption bug BEFORE doing any damage.           │
    │   → return early, no keychain writes                                   │
    │                                                                         │
    │ if fp(T-A) != fp(T-B):                                                 │
    │   → OK, proceed to step 1                                              │
    └─────────────────────────────────────────────────────────────────────────┘

Step 1: VERIFY CLI state, then conditionally back up source token

    Run `claude auth status` → returns { email: "?" }

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if email == A.email:                                                    │
    │   → CLI is on Account A (expected). Safe to backup.                    │
    │   → Read LIVE token (T-A) → Write to Backup UUID-A                     │
    │                                                                         │
    │   Keychain after:                                                       │
    │     LIVE = T-A, Backup UUID-A = T-A (refreshed), Backup UUID-B = T-B  │
    │                                                                         │
    │ if email != A.email:                                                    │
    │   → CLI is NOT on Account A (state desync).                            │
    │   → SKIP backup. The LIVE token belongs to someone else.               │
    │   → Writing it to Backup UUID-A would corrupt A's backup.              │
    │                                                                         │
    │   Keychain after: unchanged                                             │
    └─────────────────────────────────────────────────────────────────────────┘

Step 2: Read target backup

    Read Backup UUID-B → T-B
    (if missing → throw error, cannot switch)

Step 3: OVERWRITE the LIVE slot with target token

    Delete LIVE entry, then Write T-B → LIVE

    ┌─ Keychain State ─────────────────────────────────────────────────┐
    │ LIVE: "Claude Code-credentials" = T-B   ← CHANGED               │
    │ Backup UUID-A: T-A                                               │
    │ Backup UUID-B: T-B                                               │
    └──────────────────────────────────────────────────────────────────┘

    From this moment, any `claude` CLI call uses T-B (Account B's token).

Step 4: VERIFY the switch worked

    Run `claude auth status` → returns { email: "?", loggedIn: ? }

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if !loggedIn:                                                           │
    │   → Token invalid. throw switchVerificationFailed                      │
    │                                                                         │
    │ if email == B.email:                                                    │
    │   → SUCCESS. Claude CLI now operates as Account B.                     │
    │                                                                         │
    │ if email != B.email (e.g. still A, or unknown):                        │
    │   → Backup T-B was CORRUPTED (contained wrong account's token).        │
    │   → throw switchWrongAccount(expected: B, actual: email)               │
    │   → User sees: "Switch failed: expected B@... but got A@...            │
    │     Try removing and re-adding the account."                           │
    └─────────────────────────────────────────────────────────────────────────┘

Step 5: POST-SWITCH diagnostics

    Read LIVE → fp(LIVE)
    Compare fp(LIVE) == fp(T-B)?  (should match, log warning if not)

    Update app state: A.isActive=false, B.isActive=true, activeAccount=B
```

---

## Login New Account — Complete Token Flow

**Precondition:** App has Account-A (active). LIVE keychain = T-A.
User clicks "Login New Account" and logs in as B (or A again) in browser.

```
                                    ┌─ Keychain State ─────────────────────────┐
                                    │ LIVE: "Claude Code-credentials" = T-A    │
                                    │ Backup UUID-A: T-A                       │
                                    └──────────────────────────────────────────┘

Step 0: Record pre-login fingerprint (keychain read only)

    Read LIVE → T-A → fp_before = fp(T-A)

Step 1: VERIFY CLI, then conditionally back up current account

    Run `claude auth status` → returns { email: "?" }

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if email == A.email:                                                    │
    │   → CLI matches active account. Safe to backup.                        │
    │   → Read LIVE (T-A) → Write to Backup UUID-A                           │
    │   (This ensures A's backup has the freshest token before we replace it)│
    │                                                                         │
    │ if email != A.email:                                                    │
    │   → State desync. SKIP backup to avoid corruption.                     │
    │   → A's existing backup (from when it was first added) remains intact. │
    └─────────────────────────────────────────────────────────────────────────┘

Step 2: Run `claude auth login` (opens browser, blocks until complete)

    Claude CLI starts local HTTP server → opens browser → user logs in.

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ SCENARIO A: User logs in as DIFFERENT account (B)                      │
    │   → Claude CLI receives new OAuth tokens for B                         │
    │   → CLI writes T-B (new token) to LIVE keychain entry                  │
    │   → CLI process exits (code 0)                                         │
    │                                                                         │
    │   Keychain after:                                                       │
    │     LIVE = T-B  ← CHANGED by Claude CLI                                │
    │     Backup UUID-A = T-A  (preserved)                                   │
    │                                                                         │
    │ SCENARIO B: User logs in as SAME account (A again)                     │
    │   → Claude CLI receives new OAuth tokens for A                         │
    │   → CLI writes T-A' (new/refreshed token for A) to LIVE               │
    │   → CLI process exits (code 0)                                         │
    │                                                                         │
    │   Keychain after:                                                       │
    │     LIVE = T-A'  ← CHANGED (refreshed A token, different from old T-A)│
    │     Backup UUID-A = T-A  (old token, still valid until expiry)         │
    └─────────────────────────────────────────────────────────────────────────┘

Step 3: Read new token, compare fingerprint

    Read LIVE → new token → fp_after

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if fp_after != fp_before:                                               │
    │   → Token changed. This confirms a new login happened.                 │
    │   → Could be different account OR same account with refreshed token.   │
    │   → Log: "Token fingerprint CHANGED (xxxx → yyyy)"                     │
    │                                                                         │
    │ if fp_after == fp_before:                                               │
    │   → Token did NOT change. Possible causes:                             │
    │     - Login didn't actually complete (user closed browser)             │
    │     - User logged into same account AND server returned same token     │
    │   → Log WARNING (but continue — step 4 will determine via email)      │
    └─────────────────────────────────────────────────────────────────────────┘

Step 4: Get auth status to identify WHO is logged in

    Run `claude auth status` → returns { email: "X@...", loggedIn: true }

    (if !loggedIn → error "Login did not complete", return early)

Step 5: Duplicate check by email

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if email already exists in accounts[]:                                  │
    │   → User logged in as an account we already have.                      │
    │   → Read LIVE → Write to that account's backup UUID (refresh token)    │
    │   → Show: "Account already exists - token refreshed"                   │
    │   → return early (no new account created)                              │
    │                                                                         │
    │   Example: user has A, logs in as A again.                             │
    │   Result:                                                               │
    │     LIVE = T-A' (refreshed)                                            │
    │     Backup UUID-A = T-A' (updated)                                     │
    │     Account list unchanged. A stays active.                            │
    │                                                                         │
    │ if email is NEW (not in accounts[]):                                    │
    │   → This is a genuinely new account. Proceed to step 6.               │
    └─────────────────────────────────────────────────────────────────────────┘

Step 6: Create new account, capture its token

    Create Account-B model (email, org, subscription from status)
    Read LIVE (T-B) → Write to Backup UUID-B

    ┌─ Keychain State ─────────────────────────────────────────────────┐
    │ LIVE: "Claude Code-credentials" = T-B                            │
    │ Backup UUID-A: T-A  (Account A's original token, preserved)     │
    │ Backup UUID-B: T-B  (Account B's fresh token)                   │
    └──────────────────────────────────────────────────────────────────┘

Step 7: Update app state

    for all accounts: isActive = false
    Append Account-B to accounts[]
    activeAccount = Account-B
    Save to UserDefaults

    ┌─ Final State ────────────────────────────────────────────────────┐
    │ App: Account-A (inactive), Account-B (active)                    │
    │ Keychain LIVE = T-B (Account B)                                  │
    │ Keychain Backup UUID-A = T-A (Account A — ready for switch)     │
    │ Keychain Backup UUID-B = T-B (Account B)                        │
    │                                                                   │
    │ User can now click "Switch" on Account-A to go back.            │
    │ That will: write T-A → LIVE, verify email == A → done.          │
    └──────────────────────────────────────────────────────────────────┘
```

---

## Re-authenticate Account — Complete Token Flow

Used to fix a stale/corrupted backup token without removing the account.
The user must log in as the **same email** as the account being re-authenticated.

**Example:** Account-A's backup was corrupted (contains T-B instead of T-A).

```
                                    ┌─ Keychain State (CORRUPTED) ─────────────┐
                                    │ LIVE: "Claude Code-credentials" = T-B    │
                                    │ Backup UUID-A: T-B  ← WRONG! should be  │
                                    │                       T-A                │
                                    │ Backup UUID-B: T-B                       │
                                    └──────────────────────────────────────────┘

    User clicks ↻ on Account-A.

Step 1: Back up current active account (if different from target)

    Active account = B, target = A, so active != target.
    Run `claude auth status` → email == B.email?
      YES → Read LIVE (T-B) → Write to Backup UUID-B (refresh B's backup)

Step 2: Run `claude auth login` (opens browser)

    User must log in as A@... in the browser.
    CLI writes T-A' (fresh token for A) → LIVE

    ┌─ Keychain State ─────────────────────────────────────────────────┐
    │ LIVE = T-A'  ← CHANGED by CLI                                   │
    │ Backup UUID-A: T-B  (still corrupted, not yet fixed)            │
    │ Backup UUID-B: T-B  (correct)                                   │
    └──────────────────────────────────────────────────────────────────┘

Step 3: VERIFY email matches the target account

    Run `claude auth status` → returns { email: "?" }

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if email == A.email:                                                    │
    │   → Correct! User logged in as the right account. Proceed to step 4.  │
    │                                                                         │
    │ if email != A.email:                                                    │
    │   → User logged in as the wrong account.                               │
    │   → Show error: "Logged in as X, but expected A. Token not updated."   │
    │   → return early. Backup UUID-A NOT overwritten (still corrupted,      │
    │     but at least we didn't make it worse).                             │
    └─────────────────────────────────────────────────────────────────────────┘

Step 4: Capture fresh token for the target account

    Read LIVE (T-A') → Write to Backup UUID-A

    ┌─ Keychain State (FIXED) ─────────────────────────────────────────┐
    │ LIVE = T-A'  (Account A is now active in CLI)                    │
    │ Backup UUID-A: T-A'  ← FIXED! Now contains A's real token      │
    │ Backup UUID-B: T-B   (correct)                                  │
    └──────────────────────────────────────────────────────────────────┘

Step 5: Update app state

    Account-A becomes active (it's what CLI is using now).
    User can switch back to B whenever they want.
```

---

## Passive Token Health Check (runs every 30s refresh)

No CLI calls. Keychain reads only. Detects problems without triggering any login.

```
diagnoseTokenHealth()
 │
 ├── Read LIVE token from "Claude Code-credentials"
 │   → extract fp(LIVE) = last 8 chars of accessToken
 │
 ├── For each account in accounts[]:
 │   └── Read Backup from "com.accountdock.tokens/<UUID>"
 │       → extract fp(backup)
 │       → if missing: log WARNING "account has no stored token, switch will fail"
 │
 ├── CHECK 1: Duplicate fingerprints across different accounts
 │   │
 │   │  Example of CORRUPTION:
 │   │    Account A backup fp = "hZQ2uQAA"
 │   │    Account B backup fp = "hZQ2uQAA"  ← SAME!
 │   │
 │   └── log ERROR: "CORRUPTION DETECTED: accounts [A, B] share the
 │       same token fingerprint. Use re-authenticate (↻) to fix."
 │
 └── CHECK 2: LIVE token vs active account's backup
     │
     ├── fp(LIVE) == fp(active account backup)
     │   └── log INFO: "Live token matches active account backup — OK"
     │
     ├── fp(LIVE) == fp(OTHER account backup)
     │   └── log WARNING: "STATE DESYNC: live token matches [other]
     │       but active is [active]. CLI may have been switched externally."
     │
     └── fp(LIVE) matches NO backup
         └── log WARNING: "live token doesn't match any backup.
             Token may have been refreshed by Claude CLI."
```

---

## Why `security` CLI Instead of Security Framework?

| Concern | Security Framework | `security` CLI |
|---------|-------------------|----------------|
| Claude's keychain entry | Prompt every access (we don't own the ACL) | "Always Allow" persists |
| Our own keychain entries | Prompt on every Debug rebuild (code signature changes) | "Always Allow" persists |
| Production (signed) builds | Would work without prompts | Also works |
| Recommendation | Only for signed production builds | **Use for all builds** |

---

## Data Flow Overview

```
┌─────────────────────────────┐
│      ~/.claude/             │
│  ├── stats-cache.json ──────┼──► StatsParser ──► UsageSummary
│  └── sessions/*.json ───────┼──► StatsParser ──► [SessionInfo]
└─────────────────────────────┘

┌─────────────────────────────┐
│      Claude CLI             │
│  `claude auth status` ──────┼──► ClaudeService ──► AuthStatus
│  `claude auth login`  ──────┼──► ClaudeService (opens browser)
└─────────────────────────────┘

┌─────────────────────────────┐
│      macOS Keychain         │
│  Claude Code-credentials ───┼──► KeychainService (via `security` CLI)
│  com.accountdock.tokens/* ───┼──► KeychainService (via `security` CLI)
└─────────────────────────────┘

         All services feed into:
    ┌──────────────────────────┐
    │  AppState (@MainActor)   │
    │  ├── accounts            │
    │  ├── activeAccount       │
    │  ├── usageSummary        │
    │  └── recentActivity      │
    └──────────┬───────────────┘
               │ @EnvironmentObject
    ┌──────────▼───────────────┐
    │  SwiftUI Views           │
    │  ├── MainMenuView        │
    │  ├── UsageDashboardView  │
    │  ├── AccountSwitcherView │
    │  └── SettingsView        │
    └──────────────────────────┘
```

---

## SwiftUI Settings Window Workaround for LSUIElement

Because AccountDock is a pure menu bar application (`LSUIElement` = `true` in `Info.plist`), SwiftUI's native `Settings { ... }` scene and `SettingsLink` often fail to open or gain foreground focus. This happens because SwiftUI does not consider the application to have any active interactive scenes when only a `MenuBarExtra` is present.

To circumvent this macOS limitation, AccountDock uses the **Lifecycle Keepalive** pattern:

1. **Hidden Keepalive Window:** At startup, we declare a 1x1 pixel `WindowGroup("AccountDockKeepalive") { HiddenWindowView() }`.
2. **True Invisibility:** The `HiddenWindowView` intercepts its own NSWindow on appearance and sets it to be `[.borderless]`, `alphaValue = 0`, positioned far off-screen (`x: -5000, y: -5000`), and configured to ignore all mouse events.
3. **Triggering Settings:** `HiddenWindowView` listens for a custom `Notification.Name.accountdockOpenSettings` via Combine. When received, it invokes the native SwiftUI `@Environment(\.openSettings)` action.
4. **Invocation:** In `MainMenuView`, when the user clicks the Settings gear icon, we post this notification. The hidden window (which SwiftUI recognizes as a valid, active scene) catches it and smoothly opens the native Settings window with proper focus.
