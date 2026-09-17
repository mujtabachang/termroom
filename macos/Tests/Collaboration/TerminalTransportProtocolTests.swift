import CryptoKit
import Foundation
import Testing
@testable import Ghostty

struct TerminalTransportProtocolTests {
    private let key = SymmetricKey(data: Data(repeating: 0xA7, count: 32))
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func frameRoundTripPreservesBinaryPayload() throws {
        let frame = try TerminalFrame(
            type: .input,
            sequence: 42,
            payload: Data([0x1B, 0x5B, 0x41, 0x00, 0xFF])
        )

        #expect(try TerminalFrameCodec.decode(TerminalFrameCodec.encode(frame)) == frame)
    }

    @Test func frameRejectsTrailingAndOversizedData() throws {
        let frame = try TerminalFrame(type: .ping, sequence: 9)
        var encoded = TerminalFrameCodec.encode(frame)
        encoded.append(0)

        #expect(throws: TerminalFrameError.trailingBytes) {
            try TerminalFrameCodec.decode(encoded)
        }
        #expect(throws: TerminalFrameError.payloadTooLarge) {
            try TerminalFrame(
                type: .input,
                sequence: 1,
                payload: Data(repeating: 0, count: TerminalFrame.maximumPayloadSize + 1)
            )
        }
    }

    @Test func signedCapabilityRoundTripPreservesAuthoritativeRole() throws {
        let capability = InviteCapability(
            sessionID: "pairing-7",
            role: .viewer,
            expiresAt: now.addingTimeInterval(300),
            nonce: "single-use-nonce"
        )

        let token = try InviteCapabilitySigner.issue(capability, key: key)
        let decoded = try InviteCapabilitySigner.verify(token, key: key, now: now)

        #expect(decoded == capability)
        #expect(decoded.role == .viewer)
    }

    @Test func capabilityRejectsTampering() throws {
        let capability = InviteCapability(
            sessionID: "pairing-7",
            role: .collaborator,
            expiresAt: now.addingTimeInterval(300)
        )
        let token = try InviteCapabilitySigner.issue(capability, key: key)
        var segments = token.split(separator: ".").map(String.init)
        var signatureBytes = Array(segments[1].utf8)
        signatureBytes[0] = signatureBytes[0] == 0x41 ? 0x42 : 0x41
        segments[1] = String(decoding: signatureBytes, as: UTF8.self)
        let tampered = segments.joined(separator: ".")

        #expect(throws: InviteCapabilityError.invalidSignature) {
            try InviteCapabilitySigner.verify(tampered, key: key, now: now)
        }
    }

    @Test func capabilityRejectsExpiryAndInvalidSession() throws {
        let expired = InviteCapability(
            sessionID: "pairing-7",
            role: .driver,
            expiresAt: now.addingTimeInterval(-1)
        )
        let token = try InviteCapabilitySigner.issue(expired, key: key)

        #expect(throws: InviteCapabilityError.expired) {
            try InviteCapabilitySigner.verify(token, key: key, now: now)
        }

        let invalid = InviteCapability(
            sessionID: "../another-session",
            role: .viewer,
            expiresAt: now.addingTimeInterval(60)
        )
        #expect(throws: InviteCapabilityError.invalidSession) {
            try InviteCapabilitySigner.issue(invalid, key: key)
        }
    }
}
