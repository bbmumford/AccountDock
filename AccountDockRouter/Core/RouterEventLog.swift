import Foundation

/// The channel the router reports its events to the app on: served,
/// refused, moved and held requests (`RouterEvent`), which the app's
/// session rates, refusals and route accounting are built from.
///
/// - The router (`RouterBrain.event`) is the only writer. Every event gets
///   the next `RouterEvent.sequence` and is appended, one line each, to the
///   newest segment file in `Router/events/`, named by its first sequence.
///   A segment past `segmentBytes` is closed and the next one begun.
/// - The app (`RouterEventFeed.read`) reads from its cursor and only whole
///   lines, so an event still being written waits for the next read, and
///   then writes the last sequence it applied to `acknowledged`.
/// - Only the writer removes segments, when it begins a new one: those
///   whose every event is acknowledged, and, while the app is away, the
///   oldest beyond `retainedBytes`, so a slow app or a rotation loses
///   nothing it could still read.
///
/// A restarted router continues after the last sequence on disk or
/// acknowledged, whichever is later, so the app never takes a new event for
/// one it already applied.
final class RouterEventLog: @unchecked Sendable {
    static let segmentBytes = 1_000_000
    static let retainedBytes = 32_000_000

    let directory: URL
    private let segmentBytes: Int
    private let retainedBytes: Int
    private let lock = NSLock()
    private var nextSequence: UInt64?
    private var current: (first: UInt64, url: URL, size: Int)?

    init(directory: URL, segmentBytes: Int = RouterEventLog.segmentBytes, retainedBytes: Int = RouterEventLog.retainedBytes) {
        self.directory = directory
        self.segmentBytes = segmentBytes
        self.retainedBytes = retainedBytes
    }

    /// Assigns the event its sequence and appends it.
    func append(_ event: RouterEvent) {
        lock.lock(); defer { lock.unlock() }
        if nextSequence == nil { resume() }
        guard let sequence = nextSequence else { return }
        var event = event
        event.sequence = sequence
        guard var line = try? RouterConfig.encoder().encode(event) else { return }
        line.append(0x0A)
        if current.map({ $0.size >= segmentBytes }) ?? true { begin(at: sequence) }
        guard let segment = current else { return }
        RouterFiles.append(line, to: segment.url)
        current?.size += line.count
        nextSequence = sequence + 1
    }

    /// Finds where the log left off: after the last whole event on disk or
    /// the acknowledged one. A newest segment that ends inside a line, as
    /// after a crash mid-write, is closed so no event joins the torn line.
    private func resume() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let segments = RouterEventFeed.segments(in: directory)
        var last = RouterEventFeed.acknowledged(directory: directory) ?? 0
        if let newest = segments.last, let data = try? Data(contentsOf: newest.url) {
            if let sequence = RouterEventFeed.lastSequence(in: data) { last = max(last, sequence) }
            if data.last == 0x0A || data.isEmpty { current = (newest.first, newest.url, data.count) }
        }
        nextSequence = last + 1
    }

    /// Begins the segment whose first event is `sequence`, then removes the
    /// segments the app no longer needs.
    private func begin(at sequence: UInt64) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(RouterEventFeed.segmentName(first: sequence))
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        current = (sequence, url, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        prune(keeping: sequence)
    }

    private func prune(keeping newest: UInt64) {
        let acknowledged = RouterEventFeed.acknowledged(directory: directory) ?? 0
        var segments = RouterEventFeed.segments(in: directory).filter { $0.first < newest }
        // A closed segment's events end where the next one begins.
        var index = 0
        while index < segments.count {
            let end = (index + 1 < segments.count ? segments[index + 1].first : newest) - 1
            if end <= acknowledged {
                try? FileManager.default.removeItem(at: segments[index].url)
                segments.remove(at: index)
            } else {
                index += 1
            }
        }
        var total = segments.reduce(0) { $0 + ((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        while total > retainedBytes, let oldest = segments.first {
            total -= (try? oldest.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: oldest.url)
            segments.removeFirst()
        }
    }
}

/// Where the app has read the router's events to: the last sequence it
/// took, and the segment and byte it stopped at, so the next read starts
/// there instead of at the segment's top.
struct RouterEventCursor: Equatable, Sendable {
    var sequence: UInt64
    var segment: UInt64?
    var offset: UInt64 = 0

    init(sequence: UInt64, segment: UInt64? = nil, offset: UInt64 = 0) {
        self.sequence = sequence; self.segment = segment; self.offset = offset
    }
}

/// The app's side of `RouterEventLog`.
enum RouterEventFeed {
    static let acknowledgedName = "acknowledged"
    private static let prefix = "events-"
    private static let suffix = ".jsonl"

    static func segmentName(first: UInt64) -> String {
        let digits = String(first)
        return prefix + String(repeating: "0", count: max(0, 20 - digits.count)) + digits + suffix
    }

    /// The segments in `directory`, oldest first.
    static func segments(in directory: URL) -> [(first: UInt64, url: URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (first: UInt64, url: URL)? in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix),
                  let first = UInt64(name.dropFirst(prefix.count).dropLast(suffix.count)) else { return nil }
            return (first, directory.appendingPathComponent(name))
        }.sorted { $0.first < $1.first }
    }

    /// The last sequence the app applied, as it acknowledged it.
    static func acknowledged(directory: URL) -> UInt64? {
        (try? String(contentsOf: directory.appendingPathComponent(acknowledgedName), encoding: .utf8))
            .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Records that every event through `sequence` was applied, so the
    /// router may remove the segments holding only those.
    static func acknowledge(_ sequence: UInt64, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(String(sequence).utf8).write(to: directory.appendingPathComponent(acknowledgedName), options: .atomic)
    }

    /// The events after `cursor`, oldest first, and the cursor to read on
    /// from. Only whole lines are read; a line still being written is left
    /// for the next read. When the cursor's segment is gone, reading starts
    /// at the segment holding the event after its sequence.
    static func read(directory: URL, after cursor: RouterEventCursor) -> (events: [RouterEvent], cursor: RouterEventCursor) {
        let segments = segments(in: directory)
        guard !segments.isEmpty else { return ([], cursor) }
        var startIndex: Int
        var offset: UInt64 = 0
        if let segment = cursor.segment, let index = segments.firstIndex(where: { $0.first == segment }) {
            startIndex = index
            offset = cursor.offset
        } else {
            startIndex = segments.lastIndex(where: { $0.first <= cursor.sequence + 1 }) ?? 0
        }
        let decoder = RouterConfig.decoder()
        var events: [RouterEvent] = []
        var next = cursor
        for index in startIndex..<segments.count {
            let segment = segments[index]
            guard let handle = try? FileHandle(forReadingFrom: segment.url) else { continue }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            let start = index == startIndex && offset <= end ? offset : 0
            try? handle.seek(toOffset: start)
            let data = (try? handle.readToEnd()) ?? Data()
            let whole = data.lastIndex(of: 0x0A).map { data[data.startIndex...$0] } ?? Data()
            for line in whole.split(separator: 0x0A) {
                guard let event = try? decoder.decode(RouterEvent.self, from: Data(line)),
                      let sequence = event.sequence, sequence > next.sequence else { continue }
                events.append(event)
                next.sequence = sequence
            }
            next.segment = segment.first
            next.offset = start + UInt64(whole.count)
        }
        return (events, next)
    }

    /// The sequence of the last whole event in a segment's bytes.
    static func lastSequence(in data: Data) -> UInt64? {
        let decoder = RouterConfig.decoder()
        let whole = data.lastIndex(of: 0x0A).map { data[data.startIndex...$0] } ?? Data()
        for line in whole.split(separator: 0x0A).reversed() {
            if let sequence = (try? decoder.decode(RouterEvent.self, from: Data(line)))?.sequence { return sequence }
        }
        return nil
    }
}
