import XCTest
@testable import AccountDock

/// Every launch runs in a session slot of its own, which AccountDock fills
/// for an account: a pinned session's pin alone, else the one its session
/// last ran on, the pool's pick, or the active one. A resumed session takes
/// back the slot it had, rewritten for its pin when it is pinned. Without
/// AccountDock running the CLI starts unchanged; while it is starting, a
/// launch waits for its first pass. Claude's launcher runs against a
/// stand-in `claude` that prints the slot it was given and its arguments;
/// the responder writes account files only, never a Keychain item.
final class SessionSlotLaunchTests: XCTestCase {
    private var temp: URL!
    private var slots: SessionSlots!
    private var harness: LauncherHarness!
    private let active = UUID()
    private let pooled = UUID()
    private let other = UUID()

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("SessionSlotLaunch-\(UUID().uuidString)",
                                                                             isDirectory: true)
        let home = temp.appendingPathComponent("home with space", isDirectory: true)
        let realBin = temp.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        let real = realBin.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s|%s' \"${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}\" \"$*\"\n"
            .write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        slots = try XCTUnwrap(SessionSlots(.claudeCode, home: home))
        try slots.installLauncher()
        try FileManager.default.createDirectory(at: slots.sessionRoot, withIntermediateDirectories: true)
        harness = LauncherHarness(slots: slots, realBin: realBin)
    }

    override func tearDownWithError() throws {
        harness.stopResponding()
        harness.stopDock()
        try? FileManager.default.removeItem(at: temp)
    }

    private func slotPath(of output: String) -> String { String(output.split(separator: "|").first ?? "") }

    private func slot(at path: String) -> SessionSlots.SessionSlot? {
        slots.sessionSlots().first { $0.directory.path == path }
    }

    /// A claimed slot as a session that has ended leaves it, recorded for
    /// `session` and offered back to it, at `path` when given.
    private func endedSlot(account: UUID, session: String, claimer: Int32? = nil, at path: URL? = nil) throws -> URL {
        let directory = path ?? slots.sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(SessionSlots.claimedMarker),
                                                withIntermediateDirectories: true)
        if let claimer {
            try "\(claimer)\n".write(to: directory.appendingPathComponent(SessionSlots.claimedMarker + "/" + SessionSlots.claimerFile),
                                     atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(slots.assign(directory, to: account, reason: "test"))
        XCTAssertTrue(slots.recordSession(session, folder: temp.path, in: directory))
        XCTAssertTrue(slots.markReclaimable(directory))
        return directory
    }

    func testWithoutAccountDockRunningTheCLIStartsUnchangedAndNoSlotIsMade() throws {
        slots.writePool([(slots.directory(for: pooled).path, 1)])
        XCTAssertEqual(try harness.launch(["-p"]), "|-p", "no AccountDock has ever run here")
        try harness.startDock()
        harness.stopDock()
        let started = Date()
        XCTAssertEqual(try harness.launch(["-p"]), "|-p", "the AccountDock that wrote its mark has ended")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(slots.sessionSlots().isEmpty)
    }

    func testANewSessionGetsASlotOfItsOwnOnThePoolsPickAndNoSlotIsMadeAhead() throws {
        try harness.startDock()
        harness.respond(active: active)
        slots.writePool([(slots.directory(for: pooled).path, 1)])
        let started = Date()
        let output = try harness.launch(["-p"])
        let elapsed = Date().timeIntervalSince(started)
        let path = slotPath(of: output)
        XCTAssertTrue(path.hasPrefix(slots.sessionRoot.path + "/"), output)
        XCTAssertTrue(output.hasSuffix("|-p"))
        let made = try XCTUnwrap(slot(at: path))
        XCTAssertEqual(made.account, pooled)
        XCTAssertNotNil(made.claimedAt, "claimed from the moment it appears")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.directory.appendingPathComponent(SessionSlots.wantedFile).path))
        XCTAssertNotNil(try? String(contentsOf: made.directory.appendingPathComponent(SessionSlots.claimedMarker + "/" + SessionSlots.claimerFile),
                                    encoding: .utf8))
        XCTAssertLessThan(elapsed, 3, "a slot filled on request starts its session within seconds")
        XCTAssertFalse(slots.takeSlotRequests(), "the launcher removes its request")

        // A second launch gets another slot, never the first one's.
        let second = slotPath(of: try harness.launch(["-p"]))
        XCTAssertNotEqual(second, path)
        XCTAssertEqual(slots.sessionSlots().count, 2)
    }

    func testANewSessionWithNoPoolGoesOnTheActiveAccountInItsOwnSlot() throws {
        try harness.startDock()
        harness.respond(active: active)
        let output = try harness.launch(["-p"])
        XCTAssertEqual(slot(at: slotPath(of: output))?.account, active)
    }

    func testAResumedSessionAsksForTheAccountItRanOnAndNamesItself() throws {
        try harness.startDock()
        let asked = Locked<[SessionSlots.WantedSlot]>([])
        harness.respond(active: active) { [slots] request, account in
            asked.mutate { $0.append(request) }
            _ = slots!.assign(request.directory, to: account, reason: "test.fill")
        }
        slots.writePool([(slots.directory(for: pooled).path, 1)])
        slots.writeResumes([(session: "abc-123", path: slots.directory(for: other).path),
                            (session: "on-active", path: SessionSlots.activeEntry)])
        let output = try harness.launch(["--resume", "abc-123"])
        XCTAssertEqual(slot(at: slotPath(of: output))?.account, other)
        XCTAssertTrue(output.hasSuffix("|--resume abc-123"))
        XCTAssertEqual(asked.value.first?.session, "abc-123")
        XCTAssertEqual(slot(at: slotPath(of: try harness.launch(["-r", "on-active"])))?.account, active)
        XCTAssertEqual(slot(at: slotPath(of: try harness.launch(["--resume=unknown"])))?.account, pooled)
    }

    func testAResumedSessionTakesBackTheSlotItHadAndItsAccount() throws {
        try harness.startDock()
        harness.respond(active: active)
        slots.writePool([(slots.directory(for: pooled).path, 1)])
        let own = try endedSlot(account: other, session: "4f2a-session")
        slots.writeResumes([(session: "4f2a-session", path: own.path)])

        XCTAssertEqual(try harness.launch(["--resume", "4f2a-session"]), own.path + "|--resume 4f2a-session")
        let taken = try XCTUnwrap(slot(at: own.path))
        XCTAssertNil(taken.reclaimableSince, "the offer is taken with the slot")
        XCTAssertEqual(taken.account, other, "it keeps the account it had")
        XCTAssertFalse(slots.retractReclaimable(own), "AccountDock can no longer take the offer back")

        // A second launch of the same session finds the slot taken and
        // asks for a slot of its own on that slot's account.
        let again = slotPath(of: try harness.launch(["--resume", "4f2a-session"]))
        XCTAssertNotEqual(again, own.path)
        XCTAssertEqual(slot(at: again)?.account, other)
    }

    func testASlotWhoseClaimerStillRunsWithItIsNotTakenBack() throws {
        try harness.startDock()
        harness.respond(active: active)
        let directory = slots.sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["30"]
        holder.environment = [slots.isolation.directoryVariable: directory.path]
        try holder.run()
        defer { holder.terminate() }
        Thread.sleep(forTimeInterval: 0.2)
        let own = try endedSlot(account: other, session: "busy-session", claimer: holder.processIdentifier, at: directory)
        XCTAssertEqual(own.path, directory.path)
        slots.writeResumes([(session: "busy-session", path: own.path)])
        let output = try harness.launch(["--resume", "busy-session"])
        XCTAssertNotEqual(slotPath(of: output), own.path, "its process still runs in it")
        XCTAssertNotNil(slot(at: own.path)?.reclaimableSince)

        // A process that started after the claim was written was given the
        // claimer's ID since, as after a restart: the claimer has ended.
        let reused = try endedSlot(account: other, session: "reused-session", claimer: holder.processIdentifier)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: reused.appendingPathComponent(SessionSlots.claimedMarker + "/" + SessionSlots.claimerFile).path)
        slots.writeResumes([(session: "busy-session", path: own.path), (session: "reused-session", path: reused.path)])
        XCTAssertEqual(slotPath(of: try harness.launch(["--resume", "reused-session"])), reused.path)

        // Once that process has ended, the slot is its session's again.
        holder.terminate()
        holder.waitUntilExit()
        XCTAssertEqual(slotPath(of: try harness.launch(["--resume", "busy-session"])), own.path)
    }

    func testAContinueInAFolderTakesBackTheSlotTheResumeFileNamesForIt() throws {
        try harness.startDock()
        harness.respond(active: active)
        let folder = temp.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let own = try endedSlot(account: other, session: "c0ffee")
        slots.writeResumes([(session: folder.resolvingSymlinksInPath().path, path: own.path)])
        XCTAssertEqual(try harness.launch(["--continue"], directory: folder), own.path + "|--continue")
        XCTAssertNotEqual(slotPath(of: try harness.launch(["-c"], directory: temp)), own.path, "another folder")
    }

    func testWhileAccountDockIsStartingALaunchWaitsForItsFirstPass() throws {
        try harness.startDock(ready: false)
        harness.respond(active: active)
        let done = expectation(description: "the launch went on")
        let result = Locked("")
        let started = Date()
        DispatchQueue.global().async { [harness] in
            let output = (try? harness!.launch(["-p"])) ?? ""
            result.mutate { $0 = output }
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(result.value, "", "still waiting for the first pass")
        XCTAssertTrue(slots.sessionSlots().isEmpty, "no slot is asked for before the resume file is written")
        harness.markReady()
        wait(for: [done], timeout: 10)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(slot(at: slotPath(of: result.value))?.account, active)
    }

    func testAccountDockEndingWhileALaunchWaitsStartsTheCLIUnchanged() throws {
        try harness.startDock(ready: false)
        let done = expectation(description: "the launch went on")
        let result = Locked("")
        DispatchQueue.global().async { [harness] in
            let output = (try? harness!.launch(["-p"])) ?? ""
            result.mutate { $0 = output }
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.5)
        harness.stopDock()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(result.value, "|-p")
    }

    func testASlotNotFilledInTimeStartsTheCLIUnchangedAndAsksForNothingMore() throws {
        try harness.startDock()
        let output = try harness.launch(["-p"], environment: [SessionSlots.fillWaitVariable: "1"])
        XCTAssertEqual(output, "|-p")
        XCTAssertTrue(slots.wantedSlots().isEmpty, "the launcher withdraws its request")
        XCTAssertEqual(slots.sessionSlots().count, 1, "the empty slot is left for the pass that removes unread slots")
        XCTAssertNil(slots.sessionSlots().first?.account)
    }

    func testTheLauncherMarksMatchWhatALaunchReads() throws {
        slots.markStarted(pid: 4321, name: "AccountDock")
        XCTAssertEqual(try String(contentsOf: slots.startedFile, encoding: .utf8), "4321\tAccountDock\n")
        slots.markReady(pid: 4321)
        XCTAssertEqual(slots.readyPID(), 4321)
        slots.markStarted(pid: 4321, name: "AccountDock")
        XCTAssertNil(slots.readyPID(), "a new start clears a ready mark, whose process ID may come round again")
    }

    func testTheFilledAccountIsThePinAloneElseTheOneAskedForThenTheActiveOne() {
        let (pin, asked, current) = (UUID(), UUID(), UUID())
        XCTAssertEqual(AppState.filledSlotAccounts(pinned: pin, requested: asked, active: current), [pin],
                       "a pinned session comes back on its pin, never on another account")
        XCTAssertEqual(AppState.filledSlotAccounts(pinned: nil, requested: asked, active: current), [asked, current])
        XCTAssertEqual(AppState.filledSlotAccounts(pinned: nil, requested: nil, active: current), [current])
        XCTAssertEqual(AppState.filledSlotAccounts(pinned: nil, requested: current, active: current), [current])
    }

    /// The responder AccountDock's fill stands in for: each slot asked for
    /// goes to `filledSlotAccounts` for the session's pin in `pins`.
    private func respondWithPins(_ pins: [String: UUID]) {
        let slots = slots!
        let active = active
        harness.respond(active: active) { request, _ in
            let pinned = request.session.flatMap { pins[$0] }
            guard let account = AppState.filledSlotAccounts(pinned: pinned, requested: request.account, active: active).first
            else { return }
            _ = slots.fill(request.directory, account: account, credential: nil, reason: "test.fill", session: request.session)
        }
    }

    func testAPinnedSessionWhoseOldSlotWasOnAnotherAccountReturnsOnItsPin() throws {
        let pin = UUID()
        // Its slot is offered only once it holds the pin's credential, and
        // then serves the pin; until then it is not offered at all.
        XCTAssertEqual(AppState.reclaimAccount(own: other, pinned: pin, pinServed: true), pin)
        XCTAssertNil(AppState.reclaimAccount(own: other, pinned: pin, pinServed: false))
        XCTAssertEqual(AppState.reclaimAccount(own: pin, pinned: pin, pinServed: false), pin)

        try harness.startDock()
        respondWithPins(["pinned-1": pin, "pinned-2": pin])
        // Offered, rewritten for the pin: taken back on the pin.
        let rewritten = try endedSlot(account: pin, session: "pinned-1")
        // Not offered (the pin could not be written to it): a slot of its own
        // filled for the pin, although the old slot was on another account.
        let notOffered = slots.sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: notOffered.appendingPathComponent(SessionSlots.claimedMarker),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(slots.assign(notOffered, to: other, reason: "test"))
        slots.writeResumes([(session: "pinned-1", path: rewritten.path), (session: "pinned-2", path: notOffered.path)])

        XCTAssertEqual(slotPath(of: try harness.launch(["--resume", "pinned-1"])), rewritten.path)
        XCTAssertEqual(slot(at: rewritten.path)?.account, pin)
        let fresh = slotPath(of: try harness.launch(["--resume", "pinned-2"]))
        XCTAssertNotEqual(fresh, notOffered.path)
        XCTAssertEqual(slot(at: fresh)?.account, pin)
    }

    func testAPinnedSessionWhosePinIsSpentReturnsThereAndIsHeld() throws {
        let pin = UUID()
        try harness.startDock()
        respondWithPins(["spent-pin": pin])
        slots.writePool([(slots.directory(for: pooled).path, 1)])
        slots.writeResumes([(session: "spent-pin", path: slots.directory(for: pin).path)])
        // It lands on its pin, here with no credential to write, never on
        // the pool's account.
        let output = try harness.launch(["--resume", "spent-pin"])
        XCTAssertEqual(slot(at: slotPath(of: output))?.account, pin)
        // Running there, its slot stays on the pin that cannot serve it, and
        // is marked kept so the pinned hold and the Sessions page say why.
        let choice = AppState.slotChoice(current: pin, pinned: pin, requested: nil, balance: pooled,
                                         cannotServe: { $0 == pin }, modelSpent: false, byWeight: [pooled],
                                         placed: pooled, fallback: pooled)
        XCTAssertEqual(choice.target, pin)
        XCTAssertTrue(choice.keptPinned)
    }

    func testAnUnpinnedSessionReturnsToItsLastAccount() throws {
        XCTAssertEqual(AppState.reclaimAccount(own: other, pinned: nil, pinServed: false), other)
        try harness.startDock()
        respondWithPins([:])
        slots.writePool([(slots.directory(for: pooled).path, 1)])
        let own = try endedSlot(account: other, session: "last-1")
        slots.writeResumes([(session: "last-1", path: own.path),
                            (session: "last-2", path: slots.directory(for: other).path)])
        XCTAssertEqual(slotPath(of: try harness.launch(["--resume", "last-1"])), own.path)
        XCTAssertEqual(slot(at: own.path)?.account, other)
        XCTAssertEqual(slot(at: slotPath(of: try harness.launch(["--resume", "last-2"])))?.account, other)
    }

    func testAWantedSlotIsReadFromTheLaunchersRequest() throws {
        let account = UUID()
        func request(_ text: String, claimed: Bool = true) throws -> URL {
            let directory = slots.sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if claimed {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(SessionSlots.claimedMarker),
                                                        withIntermediateDirectories: true)
                try "77\n".write(to: directory.appendingPathComponent(SessionSlots.claimedMarker + "/" + SessionSlots.claimerFile),
                                 atomically: true, encoding: .utf8)
            }
            try text.write(to: directory.appendingPathComponent(SessionSlots.wantedFile), atomically: true, encoding: .utf8)
            return directory
        }
        let resumed = try request("\(account.uuidString)\nabc-123\n")
        let new = try request("-\n\n")
        _ = try request("-\n\n", claimed: false)
        let wanted = slots.wantedSlots()
        XCTAssertEqual(wanted.count, 2, "a slot no launcher claimed asks for nothing")
        XCTAssertEqual(wanted.first { $0.directory.path == resumed.path },
                       SessionSlots.WantedSlot(directory: resumed, account: account, session: "abc-123", claimer: 77))
        XCTAssertEqual(wanted.first { $0.directory.path == new.path },
                       SessionSlots.WantedSlot(directory: new, account: nil, session: nil, claimer: 77))
        XCTAssertTrue(slots.assign(resumed, to: account, reason: "test"))
        XCTAssertEqual(slots.wantedSlots().count, 1, "a filled slot asks for nothing")
    }
}

/// A value shared between a test and the work it starts on another thread.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
