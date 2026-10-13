# Kimi provider implementation

Status: implemented natively in AccountDock. This document records the Halo
design review and the protocol decisions used by the implementation.

This assessment is based on the local `halo` and Halo Tray source, particularly
`kimi/`, `cmd/halo/accounts.go`, `overview/`, and the tray account UI.

## What Halo implements

Halo treats each Kimi coding subscription as an independently renewable provider
account. `Add Provider → Kimi coding subscription` creates a fresh alias and starts
Kimi's OAuth device grant. The server streams authorization progress to the tray;
the user can cancel the stream, which cancels the server-side login context.

Credentials live as one atomic JSON file per alias under `~/.halo/kimi`. Each
record contains a short-lived access token, rotating refresh token, device ID,
refresh expiry, tier/display metadata, persistent authentication failure state,
and learned per-model entitlement refusals. Refresh-token rotation is serialized
with a store lock and written atomically so concurrent renewal cannot lose the
only usable token.

The provider discovers models from `/models`, seeds known Kimi coding model IDs
before discovery, and withdraws models after the account's tier is refused them.
Readiness combines token servability, live usage and model entitlement. Multiple
Kimi accounts are represented as a live account set and routed only among Kimi
accounts for Kimi-native model IDs.

Kimi usage is not weekly. Its `/usages` response contains:

- a rolling five-hour session window;
- a total monthly window;
- a coding monthly window.

Halo exposes the more-consumed monthly window because either monthly constraint
can stop the subscription. The tray reuses its generic two-window display but
labels Kimi as “5-hour / monthly utilization”.

## AccountDock integration shape

Kimi is a first-class `AIProviderType`, not a special case hidden inside
Codex or Claude. The service adapter needs to own device authorization, polling,
refresh rotation, atomic per-account storage, usage decoding, model/tier metadata,
and workload switching. Shared UI, failover, ordering, exclusion and intelligent
balancing should consume provider capabilities.

The implementation uses provider-facing long-window labels and temporarily maps
Kimi's limiting monthly window through `UsageAPIResponse.sevenDay`. A later model
cleanup can rename that legacy storage field without delaying provider support.

Implemented components:

1. `KimiService` uses the installed Kimi Code CLI login flow and device identity.
2. AccountDock keeps an isolated credential copy per subscription and atomically
   promotes the selected account into Kimi Code's configured credential slot.
3. Login uses the cancellable five-minute process runner shared by other providers.
4. Rotating refresh tokens are atomically written back before subsequent use.
5. Usage decodes the five-hour window and stricter monthly total/coding window.
6. Accounts, combined Usage UI, provider visibility, menu-bar modules, failover,
   intelligent balancing and agent suspension recognize Kimi.

AccountDock should not read Halo's credential files directly. The implementation
can follow the proven protocol and storage behaviour, but it should own its Kimi
credentials so either application can be installed or removed independently.
