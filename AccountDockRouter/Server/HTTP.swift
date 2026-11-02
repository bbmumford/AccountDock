import Foundation
import Network

// MARK: - HTTP

struct HTTPRequest {
    var method: String
    var target: String
    var headers: [(String, String)]
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
    var keepAlive: Bool { header("connection")?.lowercased() != "close" }
}

enum HTTPParser {
    /// Parses one complete request from the start of `buffer`, returning it
    /// and the number of bytes it used, or nil when more bytes are needed.
    static func parse(_ buffer: Data) throws -> (HTTPRequest, Int)? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 256 * 1024 { throw URLError(.badServerResponse) }
            return nil
        }
        let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw URLError(.badServerResponse) }
        let headers: [(String, String)] = lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        var request = HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: Data())
        let bodyStart = headEnd.upperBound
        if request.header("transfer-encoding")?.lowercased().contains("chunked") == true {
            var index = bodyStart
            var body = Data()
            while true {
                guard let lineEnd = buffer[index...].range(of: Data("\r\n".utf8)) else { return nil }
                let sizeText = String(decoding: buffer[index..<lineEnd.lowerBound], as: UTF8.self)
                    .split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { throw URLError(.badServerResponse) }
                let chunkStart = lineEnd.upperBound
                if size == 0 {
                    guard let trailerEnd = buffer[chunkStart...].range(of: Data("\r\n".utf8)) else { return nil }
                    request.body = body
                    return (request, trailerEnd.upperBound - buffer.startIndex)
                }
                guard buffer.endIndex >= chunkStart + size + 2 else { return nil }
                body.append(buffer[chunkStart..<(chunkStart + size)])
                index = chunkStart + size + 2
            }
        }
        let length = Int(request.header("content-length") ?? "0") ?? 0
        guard buffer.endIndex - bodyStart >= length else { return nil }
        request.body = buffer[bodyStart..<(bodyStart + length)]
        return (request, bodyStart + length - buffer.startIndex)
    }
}

/// Thrown by the response copy once the client has closed its connection,
/// so the upstream reply stops being read and generated for nobody.
struct ClientClosed: Error {}

/// Writes one chunked HTTP/1.1 response to the client.
final class ResponseWriter: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var failed = false
    private(set) var headWritten = false
    init(_ connection: NWConnection) { self.connection = connection }

    /// True once a write failed because the client is gone, as when a user
    /// interrupts a turn and the program closes its socket.
    var clientGone: Bool { lock.withLock { failed } }

    private func send(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { self.lock.withLock { self.failed = true } }
                continuation.resume()
            })
        }
    }

    func head(_ status: Int, _ headers: [(String, String)]) async {
        headWritten = true
        var text = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        let dropped: Set<String> = ["content-length", "transfer-encoding", "connection", "keep-alive", "content-encoding"]
        for (name, value) in headers where !dropped.contains(name.lowercased()) {
            text += "\(name): \(value)\r\n"
        }
        text += "Transfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n"
        await send(Data(text.utf8))
    }

    func chunk(_ data: Data) async {
        guard !data.isEmpty else { return }
        var framed = Data(String(data.count, radix: 16).utf8)
        framed.append(contentsOf: [0x0D, 0x0A])
        framed.append(data)
        framed.append(contentsOf: [0x0D, 0x0A])
        await send(framed)
    }

    func finish() async { await send(Data("0\r\n\r\n".utf8)) }

    func complete(_ status: Int, json: Data) async {
        await head(status, [("Content-Type", "application/json")])
        await chunk(json)
        await finish()
    }
}

final class ClientConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.accountdock.router.connection")
    // Read and written on `queue` only.
    private var buffer = Data()
    private var peerClosed = false

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [connection] state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        queue.async { self.receive() }
    }

    private func receive() {
        // The pending receive holds the connection object; nothing else does.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            if let data { self.buffer.append(data) }
            if isComplete || error != nil { self.peerClosed = true }
            self.process()
        }
    }

    /// Handles the next complete request in the buffer, reading more bytes
    /// when none is complete yet. A client that has closed its side sends
    /// nothing more, so the connection is closed instead of read again: a
    /// read after the close completes at once, and asking again would spin.
    private func process() {
        do {
            guard let (request, used) = try HTTPParser.parse(buffer) else {
                if peerClosed { connection.cancel() } else { receive() }
                return
            }
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + used))
            let writer = ResponseWriter(connection)
            Task {
                await Router.handle(request, writer)
                queue.async {
                    if request.keepAlive, !writer.clientGone { self.process() } else { self.connection.cancel() }
                }
            }
        } catch {
            connection.cancel()
        }
    }
}
