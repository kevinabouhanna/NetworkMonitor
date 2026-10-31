import CommonCrypto
import CryptoKit
import Foundation

/// The ClientHello inside a QUIC client's Initial packets (RFC 9000 §17.2.2,
/// RFC 9001 §5).
///
/// Initial packets are encrypted, but with keys derived from the connection
/// ID the client chose and a salt the RFC publishes, so that anyone on the
/// path can read them. Chrome splits its ClientHello into CRYPTO frames in
/// shuffled order, and with a post-quantum key share across two packets, so
/// the frames are put back together by offset before the hello is read.
public enum QUICInitial {

    public static let version1: UInt32 = 0x0000_0001
    public static let version2: UInt32 = 0x6b33_43cf

    /// The keys protecting a client's Initial packets, from the Destination
    /// Connection ID of its first one.
    public struct Keys {
        public let key: SymmetricKey
        public let iv: [UInt8]
        public let headerProtection: [UInt8]

        public init?(destinationConnectionID: [UInt8], version: UInt32) {
            let salt: [UInt8]
            let prefix: String
            switch version {
            case QUICInitial.version1:
                salt = [0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
                        0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a]
                prefix = "quic"
            case QUICInitial.version2:
                salt = [0x0d, 0xed, 0xe3, 0xde, 0xf7, 0x00, 0xa6, 0xdb, 0x81, 0x93,
                        0x81, 0xbe, 0x6e, 0x26, 0x9d, 0xcb, 0xf9, 0xbd, 0x2e, 0xd9]
                prefix = "quicv2"
            default:
                return nil
            }
            let initial = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: destinationConnectionID),
                                               salt: salt)
            let client = Self.expand(initial, "client in", 32)
            key = Self.expand(client, "\(prefix) key", 16)
            iv = Self.expand(client, "\(prefix) iv", 12).withUnsafeBytes { Array($0) }
            headerProtection = Self.expand(client, "\(prefix) hp", 16).withUnsafeBytes { Array($0) }
        }

        /// HKDF-Expand-Label with an empty context (RFC 8446 §7.1).
        private static func expand(_ secret: some ContiguousBytes, _ label: String, _ length: Int) -> SymmetricKey {
            let full = Array("tls13 \(label)".utf8)
            let info = [UInt8(length >> 8), UInt8(length & 0xff), UInt8(full.count)] + full + [0]
            return HKDF<SHA256>.expand(pseudoRandomKey: secret, info: info, outputByteCount: length)
        }

        /// The header protection mask for a 16-byte sample (RFC 9001 §5.4.3).
        public func mask(sample: [UInt8]) -> [UInt8]? {
            guard sample.count == 16 else { return nil }
            var out = [UInt8](repeating: 0, count: 16)
            var moved = 0
            let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                                 headerProtection, headerProtection.count, nil, sample, 16, &out, 16, &moved)
            return status == CCCryptorStatus(kCCSuccess) && moved == 16 ? out : nil
        }

        /// The AEAD nonce for a packet number (RFC 9001 §5.3).
        public func nonce(packetNumber: UInt64) -> [UInt8] {
            var nonce = iv
            for index in 0..<8 { nonce[11 - index] ^= UInt8(truncatingIfNeeded: packetNumber >> (8 * index)) }
            return nonce
        }
    }

    /// The most CRYPTO data worth putting back together.
    static let cryptoLimit = 65_536

    static func serverName(in bytes: [UInt8]) -> HandshakeName.Outcome {
        guard !bytes.isEmpty else { return .needMore }
        var keys: Keys?
        var crypto: [(offset: Int, data: ArraySlice<UInt8>)] = []
        var index = 0
        var readOne = false

        packets: while index < bytes.count {
            let first = bytes[index]
            // A short header ends what a client's first flight can hold.
            guard first & 0x80 != 0 else { break }
            var reader = ByteReader(bytes, from: index + 1)
            guard let version = reader.u32() else { return .needMore }
            let type = (first & 0x30) >> 4
            let isInitial: Bool
            switch version {
            case version1: isInitial = type == 0
            case version2: isInitial = type == 1
            default: break packets
            }
            // A Retry has no length to step over, and a client never sends one.
            let isRetry = (version == version1 && type == 3) || (version == version2 && type == 0)
            guard !isRetry else { break }
            guard let dcidLength = reader.u8() else { return .needMore }
            guard dcidLength <= 20 else { break }
            guard let dcid = reader.take(dcidLength), let scidLength = reader.u8() else { return .needMore }
            guard scidLength <= 20 else { break }
            guard reader.skip(scidLength) else { return .needMore }
            if isInitial {
                guard let tokenLength = reader.varint(), reader.skip(tokenLength) else { return .needMore }
            }
            guard let length = reader.varint() else { return .needMore }
            let numberOffset = reader.index
            let end = numberOffset + length
            guard end <= bytes.count else { return .needMore }

            if isInitial {
                // The keys come from the first Initial's connection ID and
                // stay the same for the rest of the handshake.
                if keys == nil { keys = Keys(destinationConnectionID: Array(dcid), version: version) }
                guard let keys,
                      let payload = open(bytes, packetStart: index, numberOffset: numberOffset, end: end, keys: keys),
                      let frames = cryptoFrames(in: payload)
                else {
                    if !readOne { return .none }
                    index = end
                    continue
                }
                readOne = true
                crypto += frames
            }
            index = end
        }
        guard readOne else { return .none }
        return ClientHello.serverName(inHandshake: reassembled(crypto))
    }

    /// Removes header protection and decrypts one Initial packet's payload.
    static func open(_ bytes: [UInt8], packetStart: Int, numberOffset: Int, end: Int, keys: Keys) -> [UInt8]? {
        let sampleStart = numberOffset + 4
        guard sampleStart + 16 <= end, let mask = keys.mask(sample: Array(bytes[sampleStart..<sampleStart + 16]))
        else { return nil }
        let firstByte = bytes[packetStart] ^ (mask[0] & 0x0f)
        let numberLength = Int(firstByte & 0x03) + 1
        let payloadStart = numberOffset + numberLength
        guard end - payloadStart > 16 else { return nil }

        var header = Array(bytes[packetStart..<payloadStart])
        header[0] = firstByte
        var packetNumber: UInt64 = 0
        for index in 0..<numberLength {
            let position = numberOffset - packetStart + index
            header[position] ^= mask[1 + index]
            packetNumber = packetNumber << 8 | UInt64(header[position])
        }
        guard let nonce = try? AES.GCM.Nonce(data: keys.nonce(packetNumber: packetNumber)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: bytes[payloadStart..<end - 16],
                                                tag: bytes[end - 16..<end]),
              let plain = try? AES.GCM.open(box, using: keys.key, authenticating: header)
        else { return nil }
        return Array(plain)
    }

    /// The CRYPTO frames in a decrypted Initial payload, stepping over the
    /// other frames an Initial may carry (RFC 9000 §12.4).
    static func cryptoFrames(in payload: [UInt8]) -> [(offset: Int, data: ArraySlice<UInt8>)]? {
        var frames: [(offset: Int, data: ArraySlice<UInt8>)] = []
        var reader = ByteReader(payload)
        while reader.index < payload.count {
            guard let type = reader.varint() else { return nil }
            switch type {
            case 0x00, 0x01:  // PADDING, PING
                continue
            case 0x02, 0x03:  // ACK, ACK with ECN counts
                guard reader.varint() != nil, reader.varint() != nil, let ranges = reader.varint(),
                      reader.varint() != nil, ranges < 256
                else { return nil }
                for _ in 0..<ranges { guard reader.varint() != nil, reader.varint() != nil else { return nil } }
                if type == 0x03 {
                    for _ in 0..<3 { guard reader.varint() != nil else { return nil } }
                }
            case 0x06:  // CRYPTO
                guard let offset = reader.varint(), let length = reader.varint(),
                      offset <= cryptoLimit, let data = reader.take(length)
                else { return nil }
                frames.append((offset, data))
            case 0x1c:  // CONNECTION_CLOSE
                return frames
            default:
                // Nothing else belongs in an Initial packet.
                return frames
            }
        }
        return frames
    }

    /// The CRYPTO stream from its start, up to the first gap.
    static func reassembled(_ frames: [(offset: Int, data: ArraySlice<UInt8>)]) -> [UInt8] {
        var stream: [UInt8] = []
        var pending = frames.sorted { $0.offset < $1.offset }
        var progressed = true
        while progressed {
            progressed = false
            for (position, frame) in pending.enumerated() where frame.offset <= stream.count {
                let end = frame.offset + frame.data.count
                if end > stream.count { stream += frame.data.dropFirst(stream.count - frame.offset) }
                pending.remove(at: position)
                progressed = true
                break
            }
        }
        return stream
    }
}
