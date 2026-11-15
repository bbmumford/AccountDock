import XCTest
@testable import AccountDock

/// `RouterEventLog` and `RouterEventFeed`: every event the router writes
/// reaches the app exactly once, while writers race, the app reads slowly,
/// segments rotate and either side restarts.
final class RouterEventLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("router-events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func event(_ detail: String) -> RouterEvent {
        RouterEvent(kind: .turnUsage, at: Date(), session: "s", backend: "anthropic", detail: detail, contextTokens: 1_000)
    }

    /// Reads, applies and acknowledges as the app does.
    private final class App: @unchecked Sendable {
        let directory: URL
        var cursor: RouterEventCursor
        var applied: [RouterEvent] = []
        init(directory: URL) {
            self.directory = directory
            cursor = RouterEventCursor(sequence: RouterEventFeed.acknowledged(directory: directory) ?? 0)
        }
        func read() {
            let (events, next) = RouterEventFeed.read(directory: directory, after: cursor)
            applied += events
            cursor = next
            if !events.isEmpty { RouterEventFeed.acknowledge(next.sequence, directory: directory) }
        }
    }

    func testEveryEventArrivesOnceWhileWritersRaceAndTheAppReadsSlowlyAcrossRotations() {
        let log = RouterEventLog(directory: directory, segmentBytes: 2_000)
        let app = App(directory: directory)
        let writers = 8, perWriter = 300
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: writers) { writer in
                for index in 0..<perWriter { log.append(self.event("\(writer)-\(index)")) }
            }
            done.signal()
        }
        while done.wait(timeout: .now() + 0.003) == .timedOut { app.read() }
        app.read()
        XCTAssertEqual(app.applied.count, writers * perWriter)
        XCTAssertEqual(app.applied.compactMap(\.sequence), Array(1...UInt64(writers * perWriter)), "in order, none twice")
        XCTAssertEqual(Set(app.applied.compactMap(\.detail)).count, writers * perWriter)
        XCTAssertLessThan(RouterEventFeed.segments(in: directory).count, 30, "acknowledged segments are removed")
    }

    func testAnAppAwayForManyRotationsReadsEverythingWithinTheRetention() {
        let log = RouterEventLog(directory: directory, segmentBytes: 1_000)
        for index in 0..<500 { log.append(event("\(index)")) }
        XCTAssertGreaterThan(RouterEventFeed.segments(in: directory).count, 10)
        let app = App(directory: directory)
        app.read()
        XCTAssertEqual(app.applied.compactMap(\.detail), (0..<500).map(String.init))
    }

    func testALineStillBeingWrittenWaitsForTheNextRead() throws {
        let log = RouterEventLog(directory: directory)
        log.append(event("first"))
        let app = App(directory: directory)
        app.read()
        var next = event("second")
        next.sequence = 2
        var line = try RouterConfig.encoder().encode(next)
        line.append(0x0A)
        let segment = try XCTUnwrap(RouterEventFeed.segments(in: directory).last?.url)
        RouterFiles.append(line.prefix(20), to: segment)
        app.read()
        XCTAssertEqual(app.applied.compactMap(\.detail), ["first"])
        RouterFiles.append(line.dropFirst(20), to: segment)
        app.read()
        XCTAssertEqual(app.applied.compactMap(\.detail), ["first", "second"])
    }

    func testARestartedRouterContinuesAfterTheAcknowledgedSequenceAndARestartedAppAfterItsAcknowledgement() {
        let first = RouterEventLog(directory: directory, segmentBytes: 200)
        for index in 0..<10 { first.append(event("\(index)")) }
        let app = App(directory: directory)
        app.read()
        // Every segment but the newest is acknowledged and goes at the
        // next rotation; the restarted router never reuses a sequence.
        let second = RouterEventLog(directory: directory, segmentBytes: 200)
        second.append(event("after"))
        XCTAssertEqual(RouterEventFeed.read(directory: directory, after: RouterEventCursor(sequence: 10)).events.map(\.sequence), [11])
        let restartedApp = App(directory: directory)
        restartedApp.read()
        XCTAssertEqual(restartedApp.applied.compactMap(\.detail), ["after"])
    }

    func testATornLineFromACrashIsSkippedAndTheNextEventStartsANewSegment() throws {
        let log = RouterEventLog(directory: directory)
        log.append(event("before"))
        let segment = try XCTUnwrap(RouterEventFeed.segments(in: directory).last?.url)
        RouterFiles.append(Data(#"{"kind":"turnUs"#.utf8), to: segment)
        let restarted = RouterEventLog(directory: directory)
        restarted.append(event("after"))
        XCTAssertEqual(RouterEventFeed.segments(in: directory).count, 2)
        let app = App(directory: directory)
        app.read()
        XCTAssertEqual(app.applied.compactMap(\.detail), ["before", "after"])
        XCTAssertEqual(app.applied.compactMap(\.sequence), [1, 2])
    }

    func testRetentionBoundsTheLogWhileNothingIsAcknowledged() {
        let log = RouterEventLog(directory: directory, segmentBytes: 500, retainedBytes: 3_000)
        for index in 0..<300 { log.append(event("\(index)")) }
        let size = RouterEventFeed.segments(in: directory).reduce(0) {
            $0 + ((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        XCTAssertLessThan(size, 3_000 + 1_000)
        let app = App(directory: directory)
        app.read()
        XCTAssertEqual(app.applied.last?.detail, "299", "the newest events are kept")
        let sequences = app.applied.compactMap(\.sequence)
        XCTAssertEqual(sequences, Array((sequences.first ?? 1)...300), "what is kept is contiguous")
    }
}
