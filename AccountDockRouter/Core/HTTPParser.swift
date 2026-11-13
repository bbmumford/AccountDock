import Foundation

/// One request a client sent the router.
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

/// Reads requests off a client connection for the router's listener.
enum HTTPParser {
    /// The largest request body accepted. A model request with images runs
    /// to tens of megabytes; anything past this is not one.
    static let maxBodyBytes = 512 * 1024 * 1024

    /// Parses one complete request from the start of `buffer`, returning it
    /// and the number of bytes it used, or nil when more bytes are needed.
    /// A body length that is negative, not a number or over `maxBodyBytes`
    /// throws, and the listener closes the connection: every length here
    /// becomes a slice bound, where a bad one would trap and end the router
    /// with every stream it is serving.
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
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16),
                      size >= 0, body.count + size <= maxBodyBytes else { throw URLError(.badServerResponse) }
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
        var length = 0
        if let text = request.header("content-length") {
            guard let declared = Int(text), declared >= 0, declared <= maxBodyBytes else { throw URLError(.badServerResponse) }
            length = declared
        }
        guard buffer.endIndex - bodyStart >= length else { return nil }
        request.body = buffer[bodyStart..<(bodyStart + length)]
        return (request, bodyStart + length - buffer.startIndex)
    }
}
