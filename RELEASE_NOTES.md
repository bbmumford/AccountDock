# AccountDock 1.1.0

Provider-aware account ordering, safer failover, and live Codex session recovery.

## Included

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
