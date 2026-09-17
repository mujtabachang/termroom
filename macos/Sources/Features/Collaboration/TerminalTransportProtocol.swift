import CryptoKit
import Foundation

enum TerminalMessageType: UInt8, Codable, Equatable {
    case hello = 1
    case output = 2
    case input = 3
    case resize = 4
    case role = 5
    case ping = 6
    case error = 7
}

struct TerminalFrame: Equatable {
    static let version: UInt8 = 1
    static let maximumPayloadSize = 1_048_576

    let type: TerminalMessageType
    let sequence: UInt64
    let payload: Data

    init(type: TerminalMessageType, sequence: UInt64, payload: Data = Data()) throws {
        guard payload.count <= Self.maximumPayloadSize else {
            throw TerminalFrameError.payloadTooLarge
        }

        self.type = type
        self.sequence = sequence
        self.payload = payload
    }
}

enum TerminalFrameError: Error, Equatable {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownMessageType(UInt8)
    case payloadTooLarge
    case incompleteFrame
    case trailingBytes
}

enum TerminalFrameCodec {
    private static let magic = Data([0x54, 0x52, 0x4D, 0x31]) // TRM1
    private static let headerSize = 18

    static func encode(_ frame: TerminalFrame) -> Data {
        var data = Data(capacity: headerSize + frame.payload.count)
        data.append(magic)
        data.append(TerminalFrame.version)
        data.append(frame.type.rawValue)
        data.appendBigEndian(UInt32(frame.payload.count))
        data.appendBigEndian(frame.sequence)
        data.append(frame.payload)
        return data
    }

    static func decode(_ data: Data) throws -> TerminalFrame {
        guard data.count >= headerSize else { throw TerminalFrameError.incompleteFrame }
        guard data.prefix(magic.count) == magic else { throw TerminalFrameError.invalidMagic }

        let version = data[data.startIndex + 4]
        guard version == TerminalFrame.version else {
            throw TerminalFrameError.unsupportedVersion(version)
        }

        let typeValue = data[data.startIndex + 5]
        guard let type = TerminalMessageType(rawValue: typeValue) else {
            throw TerminalFrameError.unknownMessageType(typeValue)
        }

        let payloadLength = Int(data.readBigEndianUInt32(at: 6))
        guard payloadLength <= TerminalFrame.maximumPayloadSize else {
            throw TerminalFrameError.payloadTooLarge
        }

        let frameSize = headerSize + payloadLength
        guard data.count >= frameSize else { throw TerminalFrameError.incompleteFrame }
        guard data.count == frameSize else { throw TerminalFrameError.trailingBytes }

        let sequence = data.readBigEndianUInt64(at: 10)
        return try TerminalFrame(
            type: type,
            sequence: sequence,
            payload: data.subdata(in: headerSize..<frameSize)
        )
    }
}

struct InviteCapability: Codable, Equatable {
    static let expectedAudience = "termroom-terminal-v1"

    let audience: String
    let sessionID: String
    let role: CollaborationRole
    let expiresAtMilliseconds: Int64
    let nonce: String

    init(
        sessionID: String,
        role: CollaborationRole,
        expiresAt: Date,
        nonce: String = UUID().uuidString
    ) {
        self.audience = Self.expectedAudience
        self.sessionID = sessionID
        self.role = role
        self.expiresAtMilliseconds = Int64(expiresAt.timeIntervalSince1970 * 1_000)
        self.nonce = nonce
    }
}

enum InviteCapabilityError: Error, Equatable {
    case malformed
    case invalidSignature
    case expired
    case invalidAudience
    case invalidSession
    case invalidNonce
}

enum InviteCapabilitySigner {
    static func issue(_ capability: InviteCapability, key: SymmetricKey) throws -> String {
        try validateClaims(capability)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(capability)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        return "\(payload.base64URLEncodedString()).\(signature.base64URLEncodedString())"
    }

    static func verify(
        _ token: String,
        key: SymmetricKey,
        now: Date = Date()
    ) throws -> InviteCapability {
        guard token.utf8.count <= 4_096 else { throw InviteCapabilityError.malformed }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard
            segments.count == 2,
            let payload = Data(base64URLEncoded: String(segments[0])),
            let suppliedSignature = Data(base64URLEncoded: String(segments[1]))
        else { throw InviteCapabilityError.malformed }

        let expectedSignature = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        guard suppliedSignature.timingSafeEquals(expectedSignature) else {
            throw InviteCapabilityError.invalidSignature
        }

        let capability: InviteCapability
        do {
            capability = try JSONDecoder().decode(InviteCapability.self, from: payload)
        } catch {
            throw InviteCapabilityError.malformed
        }

        try validateClaims(capability)
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        guard capability.expiresAtMilliseconds > nowMilliseconds else {
            throw InviteCapabilityError.expired
        }
        return capability
    }

    private static func validateClaims(_ capability: InviteCapability) throws {
        guard capability.audience == InviteCapability.expectedAudience else {
            throw InviteCapabilityError.invalidAudience
        }
        guard
            !capability.sessionID.isEmpty,
            capability.sessionID.utf8.count <= 128,
            capability.sessionID.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
            })
        else { throw InviteCapabilityError.invalidSession }
        guard !capability.nonce.isEmpty, capability.nonce.utf8.count <= 128 else {
            throw InviteCapabilityError.invalidNonce
        }
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        reduceInteger(at: offset, byteCount: 4)
    }

    func readBigEndianUInt64(at offset: Int) -> UInt64 {
        reduceInteger(at: offset, byteCount: 8)
    }

    func reduceInteger<T: FixedWidthInteger>(
        at offset: Int,
        byteCount: Int
    ) -> T {
        self[offset..<(offset + byteCount)].reduce(0) { ($0 << 8) | T($1) }
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }

    func timingSafeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
