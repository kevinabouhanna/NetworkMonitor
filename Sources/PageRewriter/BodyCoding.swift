import Compression
import Foundation

/// A body's content coding (`Content-Encoding`), undone: gzip, deflate, br,
/// or none. Anything else, or two codings, is passed through.
public enum BodyCoding {
    public static func decode(_ body: Data, encoding: String?) throws -> Data {
        let codings = (encoding ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        guard codings.count <= 1 else { throw HTTPError.unsupported("Content-Encoding \(codings.joined(separator: ","))") }
        switch codings.first {
        case nil: return body
        case "gzip", "x-gzip": return try gunzip(body)
        case "deflate": return try inflate(body)
        case "br": return try run(body, algorithm: COMPRESSION_BROTLI)
        case let other?: throw HTTPError.unsupported("Content-Encoding \(other)")
        }
    }

    /// Far above any page; past it, decoding stops and the page passes
    /// through, so a crafted body can't fill memory.
    public static let maxDecoded = 32 * 1024 * 1024

    /// gzip (RFC 1952): its header, raw deflate, its trailer.
    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw HTTPError.malformed("gzip header")
        }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {   // FEXTRA
            guard index + 2 <= bytes.count else { throw HTTPError.malformed("gzip extra") }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        if flags & 0x08 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }   // FNAME
        if flags & 0x10 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }   // FCOMMENT
        if flags & 0x02 != 0 { index += 2 }   // FHCRC
        guard index < bytes.count - 8 else { throw HTTPError.malformed("gzip body") }
        let content = try run(Data(bytes[index..<(bytes.count - 8)]), algorithm: COMPRESSION_ZLIB)
        let size = bytes[(bytes.count - 4)...].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        guard UInt32(truncatingIfNeeded: content.count) == size else { throw HTTPError.malformed("gzip length") }
        return content
    }

    /// HTTP's "deflate": zlib-wrapped (RFC 1950), though some servers send it
    /// raw; both are read.
    static func inflate(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        if bytes.count >= 6, bytes[0] & 0x0F == 8, (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0 {
            return try run(Data(bytes[2..<(bytes.count - 4)]), algorithm: COMPRESSION_ZLIB)
        }
        return try run(data, algorithm: COMPRESSION_ZLIB)
    }

    static func run(_ data: Data, algorithm: compression_algorithm) throws -> Data {
        guard !data.isEmpty else { return Data() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw HTTPError.malformed("decoder")
        }
        defer { compression_stream_destroy(stream) }
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var output = Data()
        return try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data in
            stream.pointee.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = source.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: bufferSize - stream.pointee.dst_size)
                if output.count > maxDecoded { throw HTTPError.bodyTooLarge }
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return output
                default: throw HTTPError.malformed("compressed body")
                }
            }
        }
    }
}
