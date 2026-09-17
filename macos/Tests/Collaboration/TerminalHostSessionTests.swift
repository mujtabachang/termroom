import CryptoKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalHostSessionTests {
    private let key = SymmetricKey(data: Data(repeating: 0x73, count: 32))
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func attachesDistinctTmuxClientAndRoutesDriverInput() throws {
        let harness = try Harness(key: key)
        let token = try harness.token(role: .driver, nonce: "driver-one")
        let role = try harness.host.attach(token: token, participantID: "alice", now: now) {
            harness.frames.append($0)
        }

        #expect(role == .driver)
        #expect(harness.processes.count == 1)
        #expect(harness.processes[0].arguments == [
            "-L", "termroom-test", "attach-session", "-t", "=room-test",
        ])

        let input = try TerminalFrame(type: .input, sequence: 1, payload: Data("ls\r".utf8))
        try harness.host.receive(input, from: "alice")
        #expect(harness.processes[0].inputs == [Data("ls\r".utf8)])

        harness.processes[0].emit(Data("result".utf8))
        #expect(harness.frames.last?.type == .output)
        #expect(harness.frames.last?.payload == Data("result".utf8))
    }

    @Test func rejectsViewerAndNonDriverInput() throws {
        let harness = try Harness(key: key)
        let viewer = try harness.token(role: .viewer, nonce: "viewer-one")
        let collaborator = try harness.token(role: .collaborator, nonce: "collaborator-one")
        try harness.host.attach(token: viewer, participantID: "viewer", now: now) { _ in }
        try harness.host.attach(token: collaborator, participantID: "helper", now: now) { _ in }

        #expect(throws: TerminalHostError.inputDenied) {
            try harness.host.receive(
                try TerminalFrame(type: .input, sequence: 1, payload: Data("x".utf8)),
                from: "viewer"
            )
        }
        #expect(throws: TerminalHostError.inputDenied) {
            try harness.host.receive(
                try TerminalFrame(type: .input, sequence: 1, payload: Data("x".utf8)),
                from: "helper"
            )
        }
        #expect(harness.processes.allSatisfy(\.inputs.isEmpty))
    }

    @Test func inviteIsSingleUseAndCanBeRevoked() throws {
        let harness = try Harness(key: key)
        let token = try harness.token(role: .viewer, nonce: "only-once")
        try harness.host.attach(token: token, participantID: "first", now: now) { _ in }

        #expect(throws: TerminalHostError.inviteAlreadyUsed) {
            try harness.host.attach(token: token, participantID: "second", now: now) { _ in }
        }

        let revoked = try harness.token(role: .viewer, nonce: "revoked")
        harness.host.revokeInvite(nonce: "revoked")
        #expect(throws: TerminalHostError.inviteRevoked) {
            try harness.host.attach(token: revoked, participantID: "third", now: now) { _ in }
        }
    }

    @Test func rejectsWrongSessionStaleSequenceAndInvalidResize() throws {
        let harness = try Harness(key: key)
        let wrong = InviteCapability(
            sessionID: "another-room",
            role: .viewer,
            expiresAt: now.addingTimeInterval(300),
            nonce: "wrong-room"
        )
        let wrongToken = try InviteCapabilitySigner.issue(wrong, key: key)
        #expect(throws: TerminalHostError.wrongSession) {
            try harness.host.attach(token: wrongToken, participantID: "wrong", now: now) { _ in }
        }

        let driver = try harness.token(role: .driver, nonce: "resize-driver")
        try harness.host.attach(token: driver, participantID: "driver", now: now) { _ in }
        let ping = try TerminalFrame(type: .ping, sequence: 2)
        try harness.host.receive(ping, from: "driver")
        #expect(throws: TerminalHostError.staleSequence) {
            try harness.host.receive(ping, from: "driver")
        }

        let invalidResize = try JSONEncoder().encode(TerminalResize(columns: 0, rows: 24))
        #expect(throws: TerminalHostError.invalidResize) {
            try harness.host.receive(
                try TerminalFrame(type: .resize, sequence: 3, payload: invalidResize),
                from: "driver"
            )
        }
    }

    @Test func revokingSessionStopsEveryParticipant() throws {
        let harness = try Harness(key: key)
        for index in 0..<2 {
            let token = try harness.token(role: .viewer, nonce: "viewer-\(index)")
            try harness.host.attach(token: token, participantID: "viewer-\(index)", now: now) { _ in }
        }

        harness.host.revokeSession()
        #expect(harness.processes.allSatisfy(\.stopped))

        let token = try harness.token(role: .viewer, nonce: "late-viewer")
        #expect(throws: TerminalHostError.sessionRevoked) {
            try harness.host.attach(token: token, participantID: "late", now: now) { _ in }
        }
    }

    private final class Harness {
        let key: SymmetricKey
        let now: Date
        let host: TerminalHostSession
        let processRecorder: ProcessRecorder
        var frames: [TerminalFrame] = []

        var processes: [FakeProcess] { processRecorder.processes }

        init(
            key: SymmetricKey,
            now: Date = Date(timeIntervalSince1970: 2_000_000_000)
        ) throws {
            self.key = key
            self.now = now
            let processRecorder = ProcessRecorder()
            self.processRecorder = processRecorder
            let command = try TmuxSessionCommand(
                socketName: "termroom-test",
                sessionName: "room-test"
            )
            self.host = TerminalHostSession(
                sessionID: "room-test",
                tmuxCommand: command,
                signingKey: key,
                tmuxExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
                processFactory: { _, arguments in
                    let process = FakeProcess(arguments: arguments)
                    processRecorder.processes.append(process)
                    return process
                }
            )
        }

        func token(role: CollaborationRole, nonce: String) throws -> String {
            try InviteCapabilitySigner.issue(
                InviteCapability(
                    sessionID: "room-test",
                    role: role,
                    expiresAt: now.addingTimeInterval(300),
                    nonce: nonce
                ),
                key: key
            )
        }
    }

    private final class ProcessRecorder {
        var processes: [FakeProcess] = []
    }

    private final class FakeProcess: TerminalParticipantProcess {
        let arguments: [String]
        var onOutput: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        var inputs: [Data] = []
        var sizes: [TerminalResize] = []
        var stopped = false

        init(arguments: [String]) {
            self.arguments = arguments
        }

        func start() throws {}
        func sendInput(_ data: Data) throws { inputs.append(data) }
        func resize(_ size: TerminalResize) throws { sizes.append(size) }
        func stop() { stopped = true }
        func emit(_ data: Data) { onOutput?(data) }
    }
}
