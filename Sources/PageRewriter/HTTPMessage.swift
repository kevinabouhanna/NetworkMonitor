import Foundation

// HTTP/1.1 as the page rewriter reads it (#683): a message's head, and how its
// body ends. Strict on purpose: anything it doesn't understand is a reason to
// pass the exchange through untouched, never to guess.

/// A request's or a response's head: its first line and its headers, kept as
/// sent, so a message passed on is the bytes that came in.
public struct HTTPHead: Equatable {
    /// `GET /path HTTP/1.1`, or `HTTP/1.1 200 OK`.
    public var startLine: String
    /// In order, names as sent.
    public var headers: [(name: String, value: String)]

    public static func == (a: HTTPHead, b: HTTPHead) -> Bool {
        a.startLine == b.startLine && a.headers.map { "\($0.name):\($0.value)" } == b.headers.map { "\($0.name):\($0.value)" }
    }

    public init(startLine: String, headers: [(name: String, value: String)]) {
        self.startLine = startLine
        self.headers = headers
    }

    /// Every value of a header, by name in any case.
    public func values(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public func value(_ name: String) -> String? { values(name).first }

    public mutating func remove(_ name: String) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public mutating func set(_ name: String, _ value: String) {
        if let index = headers.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            headers[index].value = value
            headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.value != value }
        } else {
            headers.append((name, value))
        }
    }

    /// A response's status code; nil for a request or a malformed line.
    public var status: Int? {
        let parts = startLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]) else { return nil }
        return code
    }

    /// A request's method; nil for a response.
    public var method: String? {
        startLine.hasPrefix("HTTP/") ? nil : startLine.split(separator: " ").first.map(String.init)
    }

    /// A request's target, `/path?query`; nil for a response.
    public var target: String? {
        guard method != nil else { return nil }
        let parts = startLine.split(separator: " ")
        return parts.count == 3 ? String(parts[1]) : nil
    }

    /// Whether its sender keeps the connection for another message after
    /// this one, as RFC 9112 says: HTTP/1.1, unless it says `close`.
    public var keepsConnection: Bool {
        let version = status == nil ? startLine.split(separator: " ").last.map(String.init) : String(startLine.prefix(8))
        guard version == "HTTP/1.1" else { return false }
        return !values("Connection").flatMap { $0.split(separator: ",") }
            .contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "close" }
    }

    /// The head as bytes, ending with its blank line.
    public var bytes: Data {
        // Byte for byte as read: Latin-1 maps each byte to one character. A
        // line set here that Latin-1 can't hold is written in UTF-8, alone.
        func line(_ text: String) -> Data { (text + "\r\n").data(using: .isoLatin1) ?? Data((text + "\r\n").utf8) }
        var data = line(startLine)
        for header in headers { data += line("\(header.name): \(header.value)") }
        return data + Data("\r\n".utf8)
    }

    /// Reads a head from the start of `data`: the head and where the body
    /// starts, nil while it's incomplete, and throws when it's malformed.
    public static func parse(_ data: Data) throws -> (head: HTTPHead, bodyStart: Int)? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeadSize { throw HTTPError.headTooLarge }
            return nil
        }
        // Read byte for byte (a cookie may hold UTF-8), and written back the
        // same way; only the ASCII parts are ever looked at.
        guard let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .isoLatin1) else {
            throw HTTPError.malformed("a head it can't read")
        }
        var lines = text.components(separatedBy: "\r\n")
        let start = lines.removeFirst()
        guard !start.isEmpty, !start.hasPrefix(" ") else { throw HTTPError.malformed("no start line") }
        var headers: [(String, String)] = []
        for line in lines {
            // Folded headers are obsolete and ambiguous: pass through.
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw HTTPError.malformed("a folded or broken header line")
            }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(" ") else { throw HTTPError.malformed("a header name") }
            // Only ASCII spaces and tabs: read as Latin-1, a UTF-8 character's
            // last byte can look like a no-break space.
            headers.append((name, line[line.index(after: colon)...].trimmingCharacters(in: Self.blanks)))
        }
        return (HTTPHead(startLine: start, headers: headers), end.upperBound - data.startIndex)
    }

    static let blanks = CharacterSet(charactersIn: " \t")

    /// Far above any real head; past it, it isn't one.
    public static let maxHeadSize = 64 * 1024
}

/// How a message's body ends.
public enum BodyFraming: Equatable {
    case none
    case length(Int)
    case chunked
    /// Until the server closes the connection.
    case untilClose

    /// As RFC 9112 says, for a response to `requestMethod`.
    public static func forResponse(_ head: HTTPHead, requestMethod: String?) throws -> BodyFraming {
        guard let status = head.status else { throw HTTPError.malformed("status line") }
        if requestMethod == "HEAD" || (100..<200).contains(status) || status == 204 || status == 304 { return .none }
        return try framing(head) ?? .untilClose
    }

    public static func forRequest(_ head: HTTPHead) throws -> BodyFraming {
        try framing(head) ?? .none
    }

    private static func framing(_ head: HTTPHead) throws -> BodyFraming? {
        let encodings = head.values("Transfer-Encoding")
        if !encodings.isEmpty {
            // Only chunked alone is read; any other coding is passed through.
            let all = encodings.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard all == ["chunked"], head.values("Content-Length").isEmpty else {
                throw HTTPError.unsupported("Transfer-Encoding \(all.joined(separator: ","))")
            }
            return .chunked
        }
        let lengths = Set(head.values("Content-Length").map { $0.trimmingCharacters(in: .whitespaces) })
        guard !lengths.isEmpty else { return nil }
        guard lengths.count == 1, let length = Int(lengths.first!), length >= 0 else {
            throw HTTPError.malformed("Content-Length")
        }
        return .length(length)
    }
}

public enum HTTPError: Error, Equatable {
    case malformed(String)
    case unsupported(String)
    case headTooLarge
    case bodyTooLarge
    case incomplete
}

/// A chunked body's content, once all of it has arrived: the content and how
/// many bytes the chunks took, or nil while more is to come.
public enum ChunkedBody {
    /// Far above any page's chunk.
    public static let maxChunk = 64 * 1024 * 1024

    public static func decode(_ data: Data) throws -> (content: Data, used: Int)? {
        var content = Data()
        var index = data.startIndex
        while true {
            guard let lineEnd = data[index...].firstRange(of: Data("\r\n".utf8)) else { return nil }
            guard let line = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii) else {
                throw HTTPError.malformed("chunk size")
            }
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw HTTPError.malformed("a chunk size") }
            index = lineEnd.upperBound
            if size == 0 {
                // Trailers, then the blank line.
                guard let end = data[index...].firstRange(of: Data("\r\n".utf8)) else { return nil }
                if end.lowerBound == index { return (content, end.upperBound - data.startIndex) }
                guard let trailersEnd = data[index...].firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
                return (content, trailersEnd.upperBound - data.startIndex)
            }
            // A size no reply could hold is malformed, not waited for (and
            // never added to, where it would overflow).
            guard size <= maxChunk else { throw HTTPError.bodyTooLarge }
            guard data.endIndex - index >= size + 2 else { return nil }
            content.append(data[index..<(index + size)])
            index += size
            guard data[index..<(index + 2)] == Data("\r\n".utf8) else { throw HTTPError.malformed("chunk end") }
            index += 2
        }
    }
}

/// Where a body ends, followed piece by piece as it comes, none of it kept
/// (#741).
public struct BodyEnd {
    private enum Next: Equatable {
        case bytes(Int)
        /// A chunk's size, its bytes (and the line's end after them), and the
        /// lines after the last one.
        case chunkSize, chunk(Int), trailers
        case ended
    }
    private var next: Next
    private var line: [UInt8] = []

    /// Nil when only the site's closing says.
    public init?(_ framing: BodyFraming) {
        switch framing {
        case .none: next = .ended
        case .length(let length): next = length == 0 ? .ended : .bytes(length)
        case .chunked: next = .chunkSize
        case .untilClose: return nil
        }
    }

    public var isEnded: Bool { next == .ended }

    /// Far above any chunk's size line, or trailer.
    static let maxLine = 8 * 1024

    /// Takes a piece, and says how much of it was the body's: all of it, or
    /// up to its end.
    public mutating func take(_ piece: Data) throws -> Int {
        var index = piece.startIndex
        while index < piece.endIndex, next != .ended {
            switch next {
            case .bytes(let left):
                let used = min(left, piece.endIndex - index)
                index += used
                next = left == used ? .ended : .bytes(left - used)
            case .chunk(let left):
                // With its line's end, two bytes of what's left.
                let content = min(max(left - 2, 0), piece.endIndex - index)
                index += content
                var rest = left - content
                while rest > 0, rest <= 2, index < piece.endIndex {
                    guard piece[index] == (rest == 2 ? 13 : 10) else { throw HTTPError.malformed("chunk end") }
                    index += 1
                    rest -= 1
                }
                next = rest == 0 ? .chunkSize : .chunk(rest)
            case .chunkSize, .trailers:
                let byte = piece[index]
                index += 1
                guard byte == 10 else {
                    line.append(byte)
                    guard line.count <= Self.maxLine else { throw HTTPError.malformed("a chunk size") }
                    continue
                }
                guard line.last == 13 else { throw HTTPError.malformed("a chunk size") }
                let text = String(decoding: line.dropLast(), as: UTF8.self)
                line = []
                if next == .trailers {
                    if text.isEmpty { next = .ended }
                    continue
                }
                let digits = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    .trimmingCharacters(in: .whitespaces)
                guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                      let size = Int(digits, radix: 16) else { throw HTTPError.malformed("a chunk size") }
                guard size <= ChunkedBody.maxChunk else { throw HTTPError.bodyTooLarge }
                next = size == 0 ? .trailers : .chunk(size + 2)
            case .ended:
                break
            }
        }
        return index - piece.startIndex
    }
}
