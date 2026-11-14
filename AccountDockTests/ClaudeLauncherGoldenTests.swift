import XCTest
@testable import AccountDock

/// The whole text of Claude's launcher, character for character: users'
/// installed launchers are compared with it (`SessionSlots.launcherInstalled`),
/// so any change to it reinstalls every launcher and must be deliberate.
final class ClaudeLauncherGoldenTests: XCTestCase {
    func testClaudeLauncherScriptIsUnchanged() throws {
        let slots = try XCTUnwrap(SessionSlots(.claudeCode, home: URL(fileURLWithPath: "/Users/golden")))
        XCTAssertEqual(slots.launcherScript(), Self.golden)
    }

    func testClaudeSlotPathsAreUnchanged() throws {
        let slots = try XCTUnwrap(SessionSlots(.claudeCode, home: URL(fileURLWithPath: "/Users/golden")))
        XCTAssertEqual(slots.root.path, "/Users/golden/.accountdock/claude-slots")
        XCTAssertEqual(slots.launcher.path, "/Users/golden/.accountdock/bin/claude")
        XCTAssertEqual(slots.poolFile.path, "/Users/golden/.accountdock/claude-slots/pool.tsv")
        XCTAssertEqual(slots.resumeFile.path, "/Users/golden/.accountdock/claude-slots/resume.tsv")
        XCTAssertEqual(slots.sessionRoot.path, "/Users/golden/.accountdock/claude-slots/session")
        XCTAssertEqual(slots.profileLine, #"export PATH="$HOME/.accountdock/bin:$PATH"  # accountdock session slots"#)
    }

    static let golden = #"""
    #!/bin/sh
    # Installed by AccountDock: starts claude on one of the accounts in
    # '/Users/golden/.accountdock/claude-slots/pool.tsv', picked at random by weight.
    launcher='/Users/golden/.accountdock/bin/claude'
    pool='/Users/golden/.accountdock/claude-slots/pool.tsv'
    real=
    saved_ifs=$IFS
    IFS=:
    for dir in $PATH; do
      [ -n "$dir" ] || continue
      candidate="$dir/claude"
      [ -f "$candidate" ] && [ -x "$candidate" ] || continue
      [ "$candidate" -ef "$launcher" ] && continue
      real=$candidate
      break
    done
    IFS=$saved_ifs
    sessions='/Users/golden/.accountdock/claude-slots/session'
    if [ -z "$real" ]; then
      echo "claude: command not found" >&2
      exit 127
    fi
    [ -n "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" ] && exec "$real" "$@"
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] && exec "$real" "$@"
    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && exec "$real" "$@"
    [ -n "${ANTHROPIC_API_KEY:-}" ] && exec "$real" "$@"
    case "${1:-}" in
      attach|stop|logs|rm|agents|daemon|auth|login|logout|setup-token) exec "$real" "$@" ;;
    esac
    for argument in "$@"; do [ "$argument" = '--bg' ] && exec "$real" "$@"; done
    # A stale pool, as after a restart before AccountDock has written a
    # new one, is asked for again the way a spare is, and given
    # 4 seconds; without AccountDock running the CLI starts unchanged.
    fresh_pool() { [ -n "$(find "$pool" -mmin -30 2>/dev/null)" ]; }
    if ! fresh_pool; then
      [ -d "$sessions" ] || exec "$real" "$@"
      request="$sessions/.wanted.pool.$$"
      wait=${ACCOUNTDOCK_SPARE_WAIT:-4}
      case "$wait" in ''|*[!0-9]*) wait=4 ;; esac
      tries=0
      while ! fresh_pool && [ "$tries" -lt $((wait * 5)) ]; do
        : > "$request" 2>/dev/null || break
        tries=$((tries + 1))
        sleep 0.2
      done
      rm -f "$request"
      fresh_pool || exec "$real" "$@"
    fi
    resumes='/Users/golden/.accountdock/claude-slots/resume.tsv'
    resumed=
    previous=
    for argument in "$@"; do
      case "$previous" in --resume|-r) resumed=$argument ;; esac
      case "$argument" in --resume=*) resumed=${argument#--resume=} ;; esac
      previous=$argument
    done
    slot=
    if [ -n "$resumed" ] && [ -n "$(find "$resumes" -mmin -30 2>/dev/null)" ]; then
      slot=$(awk -F '\t' -v id="$resumed" '$1 == id { print $2; exit }' "$resumes" 2>/dev/null)
    fi
    [ -n "$slot" ] || slot=$(awk -F '\t' -v pid="$$" '
      BEGIN { srand(); seed = srand(); srand(seed + pid * 7919) }
      $1 > 0 { n++; weight[n] = $1; path[n] = $2; total += $1 }
      END {
        if (n == 0) exit
        r = rand() * total
        for (i = 1; i <= n; i++) { r -= weight[i]; if (r < 0) { print path[i]; exit } }
        print path[n]
      }' "$pool" 2>/dev/null)
    # Each session gets a slot of its own, so AccountDock can move it
    # alone. With no spare left, AccountDock is asked for one and given
    # 4 seconds to fill it.
    if [ -n "$slot" ] && [ "$slot" != "-" ]; then
      account=${slot##*/}
      request="$sessions/.wanted.$$"
      wait=${ACCOUNTDOCK_SPARE_WAIT:-4}
      case "$wait" in ''|*[!0-9]*) wait=4 ;; esac
      tries=0
      while :; do
        for spare in "$sessions"/*; do
          [ -f "$spare/account" ] || continue
          [ "$(cat "$spare/account" 2>/dev/null)" = "$account" ] || continue
          if mkdir "$spare/claimed" 2>/dev/null; then
            [ "$tries" -eq 0 ] || rm -f "$request"
            CLAUDE_SECURESTORAGE_CONFIG_DIR=$spare
            export CLAUDE_SECURESTORAGE_CONFIG_DIR
            exec "$real" "$@"
          fi
        done
        [ "$tries" -lt $((wait * 5)) ] || break
        : > "$request" 2>/dev/null || break
        tries=$((tries + 1))
        sleep 0.2
      done
      [ "$tries" -eq 0 ] || rm -f "$request"
    fi
    if [ -z "$slot" ] || [ "$slot" = "-" ] || [ ! -d "$slot" ]; then
      exec "$real" "$@"
    fi
    CLAUDE_SECURESTORAGE_CONFIG_DIR=$slot
    export CLAUDE_SECURESTORAGE_CONFIG_DIR
    exec "$real" "$@"

    """#
}
