import FirewallPolicy
import Foundation

/// What a request refused by its address (#699) is answered with, in place
/// of the site: an empty reply of the kind it asked for, so the page goes on
/// as if the site had nothing to send. A picture gets a transparent pixel
/// (never a broken-image icon), a script, a stylesheet or a frame nothing to
/// run or show, a WebSocket a plain refusal. Never kept by the browser, and
/// readable by the page that asked, as an empty reply from the site would be.
public enum EmptyReply {
    /// A 1×1 transparent GIF.
    static let pixel = Data([
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
    ])

    public static func bytes(for kind: RequestKind, origin: String?) -> Data {
        let status: String, type: String?, body: Data
        switch kind {
        case .image: (status, type, body) = ("200 OK", "image/gif", pixel)
        case .script: (status, type, body) = ("200 OK", "text/javascript", Data())
        case .stylesheet: (status, type, body) = ("200 OK", "text/css", Data())
        case .subdocument: (status, type, body) = ("200 OK", "text/html; charset=utf-8", Data())
        case .websocket: (status, type, body) = ("403 Forbidden", nil, Data())
        case .ping: (status, type, body) = ("204 No Content", nil, Data())
        default: (status, type, body) = ("200 OK", "text/plain", Data())
        }
        var head = "HTTP/1.1 \(status)\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        if !status.hasPrefix("204") { head += "Content-Length: \(body.count)\r\n" }
        head += "Cache-Control: no-store\r\n"
        // Only a well-formed origin is named back, so nothing the request
        // carried can add a header of its own.
        if let origin, origin.allSatisfy({ !$0.isWhitespace && $0 != "\r" && $0 != "\n" }),
           let components = URLComponents(string: origin), components.scheme != nil, components.host != nil {
            head += "Access-Control-Allow-Origin: \(origin)\r\nAccess-Control-Allow-Credentials: true\r\nVary: Origin\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
