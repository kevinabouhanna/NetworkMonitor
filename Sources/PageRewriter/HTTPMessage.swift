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

    /// The head as bytes, ending with its blank line.
    public var bytes: Data {
        var text = startLine + "\r\n"
        for header in headers { text += "\(header.name): \(header.value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    /// Reads a head from the start of `data`: the head and where the body
    /// starts, nil while it's incomplete, and throws when it's malformed.
    public static func parse(_ data: Data) throws -> (head: HTTPHead, bodyStart: Int)? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeadSize { throw HTTPError.headTooLarge }
            return nil
        }
        // Heads are ASCII; anything else is passed through, not read.
        guard let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .ascii) else {
            throw HTTPError.malformed("a head that isn't ASCII")
        }
        var lines = text.components(separatedBy: "\r\n")
        let start = lines.removeFirst()
        guard !start.isEmpty, !start.hasPrefix(" ") else { throw HTTPError.malformed("no start line") }
        var headers: [(String, String)] = []
        for line in lines {
            // Folded headers are obsolete and ambiguous: pass through.
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw HTTPError.malformed("header line \(line.prefix(40))")
            }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(" ") else { throw HTTPError.malformed("header name \(name)") }
            headers.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return (HTTPHead(startLine: start, headers: headers), end.upperBound - data.startIndex)
    }

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
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw HTTPError.malformed("chunk size \(line)") }
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
