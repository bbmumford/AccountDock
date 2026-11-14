import Foundation

private let log = FileLog("TranscriptFeed")

/// One model request a CLI session made, as its transcript records it.
struct TranscriptRequest: Equatable, Sendable {
    let session: String
    let at: Date
    /// Input, cache write and cache read tokens together.
    let contextTokens: Int
    let cacheWriteTokens: Int
    /// The part of `cacheWriteTokens` written to the one-hour cache.
    let cacheWriteLongTokens: Int
    let outputTokens: Int
    /// Seconds the prompt cache written by the request lasts; nil when it
    /// wrote none, so the session's previous lifetime still applies.
    let cacheLifetime: TimeInterval?
    /// Whether the request answered a prompt rather than a tool result.
    var startsTurn: Bool
    /// The model the session itself asked; nil for a subagent's request,
    /// which may use another model than its session.
    var model: String? = nil
    /// The provider's words when it refused the request at a usage limit.
    /// Such a request used nothing, and `AppState.ingestTranscriptRequests`
    /// reads the refusing account whole instead of recording it.
    var limitRefusal: String? = nil
    /// Cache read tokens, part of `contextTokens`; with `cacheWriteTokens`
    /// they show `CredentialAudit.noteRequest` a cache rebuilt whole.
    var cacheReadTokens: Int = 0
    /// For a subagent's request, the agent that made it, as its source
    /// names it (`TranscriptFile.agent`); nil for the session's own.
    var agent: String? = nil
    /// The model a subagent's request used, which `model` leaves out.
    var agentModel: String? = nil
    /// The name the session was given in the CLI, when its records keep
    /// one; `AppState.sessionNames` shows it.
    var sessionName: String? = nil

    /// Made by one of the session's subagents, which consume its account
    /// and never start its turns.
    var subagent: Bool { agent != nil }
}

/// A transcript file a source lists: the session its requests belong to,
/// and the subagent of that session that writes it, if one does.
struct TranscriptFile: Equatable, Sendable {
    let url: URL
    let session: String
    var agent: String? = nil

    var subagent: Bool { agent != nil }
}

/// What a source keeps between two listings of its transcripts, held by
/// `TranscriptRequestFeed` for it.
struct TranscriptListing: Sendable {
    /// A directory whose transcripts were all older than the lookback when
    /// it was last listed, by path, with its modification time then and its
    /// subdirectories. Paths, not `URL`s: a `URL` keeps the resource values
    /// read when it was listed, which would hide a later change of time.
    struct QuietDirectory: Sendable {
        var modified: Date
        var subdirectories: [String]
    }

    var quietDirectories: [String: QuietDirectory] = [:]
    var lastFullScan: Date?
}

/// What one transcript file said so far that its later lines depend on.
struct TranscriptReadState: Sendable {
    /// The session's last row was a prompt, so its next response starts a
    /// turn.
    var awaitingTurn = false
    /// The session the file's own records name, replacing the one its
    /// listing gave.
    var session: String?
    /// The subagent the file's own records say writes it.
    var agent: String?
    /// The model the session's latest records name.
    var model: String?
    /// The running total of tokens the file last reported, for a CLI that
    /// reports its totals again without a new request.
    var lastTotal: Int?
    /// The last refusal read, so a CLI that records one refusal in two
    /// rows counts once.
    var lastRefusal: String?
    var lastRefusalAt: Date?
}

/// What one transcript row records.
enum TranscriptRow {
    /// Nothing that counts.
    case none
    /// A prompt the user typed: the session's next request starts a turn.
    case prompt
    /// A request with its token use; `key`, when given, names the response,
    /// which may appear in several rows and counts once.
    case request(TranscriptRequest, key: String?)
    /// A request the provider refused at a usage limit.
    case refusal(TranscriptRequest)
}

/// A provider's session transcripts: where they are, which files hold them,
/// and what each row says. Registered as
/// `ProviderCapabilities.transcriptSource` and read by
/// `TranscriptRequestFeed`; everything provider-specific about a transcript
/// lives in the source.
protocol ProviderTranscriptSource: Sendable {
    /// Directory under the provider's config directory holding them.
    var directory: String { get }
    /// The transcript files under `root` that may hold requests made after
    /// `cutoff`. `listing` is kept across calls for the source.
    func files(under root: URL, cutoff: Date, now: Date, listing: inout TranscriptListing) -> [TranscriptFile]
    /// What one row of `file` records, given what the file said before.
    func row(_ row: [String: Any], file: TranscriptFile, state: inout TranscriptReadState) -> TranscriptRow
    /// The names the CLI keeps for `sessions`, read from `config`, its
    /// config directory; empty when it keeps none.
    func sessionNames(_ sessions: Set<String>, config: URL) -> [String: String]
}

extension ProviderTranscriptSource {
    func sessionNames(_ sessions: Set<String>, config: URL) -> [String: String] { [:] }

    /// Every `.jsonl` file under `root` modified after `cutoff`, listed
    /// again on every call: for CLIs whose transcripts are few enough, and
    /// spread over enough directories, that a walk costs less than keeping
    /// track of quiet ones. `make` names each file's session; files it
    /// returns nil for are skipped.
    func recentFiles(under root: URL, cutoff: Date, named make: (URL) -> TranscriptFile?) -> [TranscriptFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var found: [TranscriptFile] = []
        for case let url as URL in walk where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, (values?.contentModificationDate ?? .distantPast) > cutoff,
                  let file = make(url) else { continue }
            found.append(file)
        }
        return found
    }

    /// A time as transcripts write it, with or without fractions of a
    /// second.
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
}

/// Reads each request's token use from the session transcripts a CLI writes
/// (`ProviderCapabilities.transcriptSource`), as the CLI appends to them,
/// for `SessionRates` and `TurnCostModel`. Used by
/// `AppState.ingestTranscriptRequests` for sessions the router does not
/// carry.
///
/// Each file is read from where the previous read stopped, up to its last
/// complete line. A response recorded in several rows counts once, by the
/// key its source gives it.
actor TranscriptRequestFeed {
    static let shared = TranscriptRequestFeed()

    /// How far back the first read after launch looks; older requests no
    /// longer change a session's rate.
    static let initialLookback: TimeInterval = 2 * 60 * 60
    /// A file first seen larger than this is read only from this far before
    /// its end: the lookback rarely needs more, and a whole transcript of
    /// hundreds of megabytes would be held in memory at once.
    static let firstReadLimit: UInt64 = 8 * 1024 * 1024
    /// How often a source that keeps quiet directories lists them again,
    /// quiet or not, so a transcript appended to after the lookback is
    /// still read.
    static let fullScanInterval: TimeInterval = 10 * 60

    private struct FileState {
        var offset: UInt64
        var read = TranscriptReadState()
        /// The read starts inside a line, which is skipped.
        var skipsPartialLine = false
    }

    private var files: [String: FileState] = [:]
    private var counted: Set<String> = []
    private var countedOrder: [String] = []
    private var listings: [AIProviderType: TranscriptListing] = [:]

    /// Requests appended to the provider's transcripts since the last call,
    /// each carrying its session's name when the CLI keeps one.
    /// `configDirectory` replaces the provider's own, for tests.
    func newRequests(_ provider: AIProviderType, configDirectory: String? = nil,
                     now: Date = Date()) -> [TranscriptRequest] {
        guard let source = provider.capabilities.transcriptSource else { return [] }
        let config = URL(fileURLWithPath: configDirectory ?? (provider.configDirectory as NSString).expandingTildeInPath,
                         isDirectory: true)
        let root = config.appendingPathComponent(source.directory, isDirectory: true)
        let cutoff = now.addingTimeInterval(-Self.initialLookback)
        var listing = listings[provider] ?? TranscriptListing()
        let found = source.files(under: root, cutoff: cutoff, now: now, listing: &listing)
        listings[provider] = listing
        var requests: [TranscriptRequest] = []
        for file in found {
            requests += readIfChanged(file, source: source, cutoff: cutoff)
        }
        guard !requests.isEmpty else { return [] }
        let names = source.sessionNames(Set(requests.map(\.session)), config: config)
        if !names.isEmpty {
            requests = requests.map { request in
                var named = request
                named.sessionName = names[request.session]
                return named
            }
        }
        return requests.sorted { $0.at < $1.at }
    }

    private func readIfChanged(_ file: TranscriptFile, source: any ProviderTranscriptSource,
                               cutoff: Date) -> [TranscriptRequest] {
        let values = try? file.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let size = UInt64(values?.fileSize ?? 0)
        let path = file.url.path
        if files[path] == nil {
            // Files untouched within the lookback hold nothing current; a
            // file seen for the first time otherwise is read whole, as a new
            // session's is, up to `firstReadLimit` before its end.
            guard (values?.contentModificationDate ?? .distantPast) > cutoff else {
                files[path] = FileState(offset: size)
                return []
            }
            let start = size > Self.firstReadLimit ? size - Self.firstReadLimit : 0
            files[path] = FileState(offset: start, skipsPartialLine: start > 0)
        }
        guard var state = files[path] else { return [] }
        if size < state.offset { state = FileState(offset: 0) }
        guard size > state.offset else { return [] }
        let requests = read(file, source: source, state: &state, notBefore: cutoff)
        files[path] = state
        return requests
    }

    private func read(_ file: TranscriptFile, source: any ProviderTranscriptSource, state: inout FileState,
                      notBefore cutoff: Date) -> [TranscriptRequest] {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.offset)
        } catch {
            log.warning("Could not read \(file.url.lastPathComponent): \(error.localizedDescription)")
            return []
        }
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        state.offset += UInt64(end - data.startIndex + 1)
        var requests: [TranscriptRequest] = []
        var lines = data[data.startIndex...end].split(separator: UInt8(ascii: "\n"))[...]
        if state.skipsPartialLine {
            lines = lines.dropFirst()
            state.skipsPartialLine = false
        }
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch source.row(object, file: file, state: &state.read) {
            case .none:
                continue
            case .prompt:
                state.read.awaitingTurn = true
            case let .refusal(refusal):
                if refusal.at >= cutoff { requests.append(refusal) }
            case .request(var request, let key):
                if let key {
                    guard !counted.contains(key) else { continue }
                    remember(key)
                }
                request.startsTurn = !request.subagent && state.read.awaitingTurn
                if !request.subagent { state.read.awaitingTurn = false }
                if request.at >= cutoff { requests.append(request) }
            }
        }
        return requests
    }

    private func remember(_ key: String) {
        counted.insert(key)
        countedOrder.append(key)
        if countedOrder.count > 20_000 {
            let drop = countedOrder.prefix(10_000)
            counted.subtract(drop)
            countedOrder.removeFirst(10_000)
        }
    }
}
