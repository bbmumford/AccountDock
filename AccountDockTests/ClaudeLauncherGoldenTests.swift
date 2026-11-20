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
    # Installed by AccountDock: starts claude in a session slot of its own,
    # which AccountDock fills for the account the session last ran on, or
    # the one '/Users/golden/.accountdock/claude-slots/pool.tsv' picks at random by weight, or the active one.
    launcher='/Users/golden/.accountdock/bin/claude'
    root='/Users/golden/.accountdock/claude-slots'
    pool='/Users/golden/.accountdock/claude-slots/pool.tsv'
    sessions='/Users/golden/.accountdock/claude-slots/session'
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
    # AccountDock fills every session slot, and runs while the process its
    # started file names, by ID and name, runs. Without it the CLI starts
    # unchanged, and AccountDock restarts the session in a slot of its own
    # once it runs.
    dock=
    dock_name=
    [ -f "$root/started" ] && read -r dock dock_name < "$root/started"
    case "$dock" in *[!0-9]*) dock= ;; esac
    [ -n "$dock" ] && [ -n "$dock_name" ] || exec "$real" "$@"
    case "$(ps -o comm= -p "$dock" 2>/dev/null)" in
      "$dock_name"|*/"$dock_name") ;;
      *) exec "$real" "$@" ;;
    esac
    # While AccountDock is starting, its first pass over the slots, which
    # writes the pool and resume files, is waited for: its ID in the ready file.
    wait=${ACCOUNTDOCK_START_WAIT:-60}
    case "$wait" in ''|*[!0-9]*) wait=60 ;; esac
    tries=0
    ready=
    [ -f "$root/ready" ] && read -r ready < "$root/ready"
    while [ "$ready" != "$dock" ] && [ "$tries" -lt $((wait * 5)) ]; do
      kill -0 "$dock" 2>/dev/null || exec "$real" "$@"
      sleep 0.2
      tries=$((tries + 1))
      ready=
      [ -f "$root/ready" ] && read -r ready < "$root/ready"
    done
    resumes='/Users/golden/.accountdock/claude-slots/resume.tsv'
    resumed=
    previous=
    for argument in "$@"; do
      case "$previous" in --resume|-r) resumed=$argument ;; esac
      case "$argument" in --resume=*) resumed=${argument#--resume=} ;; esac
      previous=$argument
    done
    continued=
    for argument in "$@"; do
      case "$argument" in --continue|-c) continued=1 ;; esac
    done
    slot=
    if { [ -n "$resumed" ] || [ -n "$continued" ]; } && [ -n "$(find "$resumes" -mmin -30 2>/dev/null)" ]; then
      if [ -n "$resumed" ]; then
        slot=$(awk -F '\t' -v id="$resumed" '$1 == id { print $2; exit }' "$resumes" 2>/dev/null)
      else
        here=$(pwd -P 2>/dev/null)
        slot=$(awk -F '\t' -v a="$PWD" -v b="$here" '$1 == a || $1 == b { print $2; exit }' "$resumes" 2>/dev/null)
      fi
    fi
    # A session resumed into the session slot it last ran in takes it back:
    # AccountDock offers that slot once its session has ended, and the
    # rename of its reclaimable marker, which one launcher alone can make,
    # takes it, unless the process that claimed it still runs: a process
    # with its ID that started no later than the claim was written (one
    # that started later was given the ID since, as after a restart).
    # Otherwise the session asks for the account that slot serves.
    account=
    case "$slot" in
      "$sessions"/*)
        claimer=
        [ -f "$slot/claimed/pid" ] && read -r claimer < "$slot/claimed/pid"
        case "$claimer" in *[!0-9]*) claimer= ;; esac
        running=
        if [ -n "$claimer" ] && kill -0 "$claimer" 2>/dev/null; then
          running=1
          written=$(stat -f %m "$slot/claimed/pid" 2>/dev/null)
          started=$(LC_ALL=C ps -o lstart= -p "$claimer" 2>/dev/null)
          started=$(LC_ALL=C date -j -f '%a %b %e %T %Y' "$started" +%s 2>/dev/null)
          case "$written" in *[!0-9]*) written= ;; esac
          case "$started" in *[!0-9]*) started= ;; esac
          [ -n "$written" ] && [ -n "$started" ] && [ "$started" -gt $((written + 5)) ] && running=
        fi
        if [ -z "$running" ] && mv "$slot/reclaimable" "$slot/claimed/reclaimed.$$" 2>/dev/null; then
          rm -f "$slot/claimed/reclaimed.$$"
          { echo "$$" > "$slot/claimed/pid"; } 2>/dev/null
          CLAUDE_SECURESTORAGE_CONFIG_DIR=$slot
          export CLAUDE_SECURESTORAGE_CONFIG_DIR
          exec "$real" "$@"
        fi
        [ -f "$slot/account" ] && read -r account < "$slot/account"
        ;;
      */*) account=${slot##*/} ;;
      ?*) account=$slot ;;
    esac
    if [ -z "$account" ] && [ -n "$(find "$pool" -mmin -30 2>/dev/null)" ]; then
      account=$(awk -F '\t' -v pid="$$" '
        BEGIN { srand(); seed = srand(); srand(seed + pid * 7919) }
        $1 > 0 { n++; weight[n] = $1; path[n] = $2; total += $1 }
        END {
          if (n == 0) exit
          r = rand() * total
          for (i = 1; i <= n; i++) { r -= weight[i]; if (r < 0) { print path[i]; exit } }
          print path[n]
        }' "$pool" 2>/dev/null)
      account=${account##*/}
    fi
    [ -n "$account" ] || account=-
    # The session's own slot: made under a name AccountDock does not read,
    # claimed, told the account it asks for, then renamed into place whole.
    # AccountDock fills it for that account, its account file last, and is
    # given 30 seconds to; the CLI starts unchanged if it does not.
    name=$(uuidgen 2>/dev/null)
    making="$sessions/.making.$$"
    mine="$sessions/$name"
    [ -n "$name" ] && mkdir -m 700 "$making" 2>/dev/null && mkdir "$making/claimed" 2>/dev/null \
      && { echo "$$" > "$making/claimed/pid"; } 2>/dev/null \
      && { printf '%s\n%s\n' "$account" "$resumed" > "$making/wanted"; } 2>/dev/null \
      && mv "$making" "$mine" 2>/dev/null || exec "$real" "$@"
    request="$sessions/.wanted.$$"
    wait=${ACCOUNTDOCK_SLOT_WAIT:-30}
    case "$wait" in ''|*[!0-9]*) wait=30 ;; esac
    tries=0
    while [ ! -f "$mine/account" ] && [ "$tries" -lt $((wait * 5)) ]; do
      [ $((tries % 25)) -eq 0 ] && : > "$request" 2>/dev/null
      kill -0 "$dock" 2>/dev/null || break
      sleep 0.2
      tries=$((tries + 1))
    done
    rm -f "$request"
    if [ ! -f "$mine/account" ]; then
      rm -f "$mine/wanted"
      exec "$real" "$@"
    fi
    CLAUDE_SECURESTORAGE_CONFIG_DIR=$mine
    export CLAUDE_SECURESTORAGE_CONFIG_DIR
    exec "$real" "$@"

    """#
}
