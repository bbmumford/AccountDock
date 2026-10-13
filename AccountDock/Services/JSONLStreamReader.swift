import Foundation

/// Bounded-memory JSONL reader. Provider transcripts can be hundreds of MB;
/// loading an entire file as Data and then String briefly requires several
/// copies and leaves the process allocator at a very high water mark.
enum JSONLStreamReader {
    private static let chunkSize = 512 * 1024
    private static let maximumLineSize = 16 * 1024 * 1024

    @discardableResult
    static func read(
        path: String,
        startingAt offset: UInt64 = 0,
        handleLine: (Data) -> Void
    ) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }

        if offset > 0 {
            do {
                try handle.seek(toOffset: offset)
            } catch {
                return false
            }
        }

        var pending = Data()
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: chunkSize), !next.isEmpty else { break }
                chunk = next
            } catch {
                return false
            }
            autoreleasepool {
                pending.append(chunk)
                consumeCompleteLines(from: &pending, handleLine: handleLine)
                if pending.count > maximumLineSize {
                    // Oversized transcript payloads are generally embedded tool
                    // output, not usage records. Bound memory rather than asking
                    // macOS to retain an arbitrarily large JSON object.
                    pending.removeAll(keepingCapacity: false)
                }
            }
        }
        if !pending.isEmpty { autoreleasepool { handleLine(pending) } }
        return true
    }

    private static func consumeCompleteLines(
        from data: inout Data,
        handleLine: (Data) -> Void
    ) {
        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            if newline > lineStart {
                autoreleasepool { handleLine(Data(data[lineStart..<newline])) }
            }
            lineStart = data.index(after: newline)
        }
        if lineStart > data.startIndex {
            data = lineStart < data.endIndex ? Data(data[lineStart...]) : Data()
        }
    }
}
