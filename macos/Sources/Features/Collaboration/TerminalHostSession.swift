import CryptoKit
import Foundation

enum TerminalHostError: Error, Equatable {
    case wrongSession
    case inviteAlreadyUsed
    case inviteRevoked
    case sessionRevoked
    case invalidParticipantID
    case participantAlreadyAttached
    case participantNotAttached
    case staleSequence
    case inputDenied
    case resizeDenied
    case invalidResize
    case unsupportedMessage
}

struct TerminalResize: Codable, Equatable {
    let columns: UInt16
    let rows: UInt16

    var isValid: Bool {
        (1...1_000).contains(Int(columns)) && (1...1_000).contains(Int(rows))
    }
}

struct InviteCapabilityRegistry {
    private var consumedNonces: [String: Int64] = [:]
    private var revokedNonces: Set<String> = []
    private var revokedSessions: Set<String> = []

    mutating func consume(_ capability: InviteCapability, now: Date) throws {
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        consumedNonces = consumedNonces.filter { $0.value > nowMilliseconds }

        guard !revokedSessions.contains(capability.sessionID) else {
            throw TerminalHostError.sessionRevoked
        }
        guard !revokedNonces.contains(capability.nonce) else {
            throw TerminalHostError.inviteRevoked
        }
        guard consumedNonces[capability.nonce] == nil else {
            throw TerminalHostError.inviteAlreadyUsed
        }

        consumedNonces[capability.nonce] = capability.expiresAtMilliseconds
    }

    mutating func revoke(nonce: String) {
        revokedNonces.insert(nonce)
        consumedNonces.removeValue(forKey: nonce)
    }

    mutating func revoke(sessionID: String) {
        revokedSessions.insert(sessionID)
    }
}

@MainActor
protocol TerminalParticipantProcess: AnyObject {
    var onOutput: ((Data) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }

    func start() throws
    func sendInput(_ data: Data) throws
    func resize(_ size: TerminalResize) throws
    func stop()
}

/// Owns authoritative authorization and one tmux client process per remote participant. Network
/// transports only deliver framed messages and never decide whether input is permitted.
@MainActor
final class TerminalHostSession {
    typealias FrameSink = (TerminalFrame) -> Void
    typealias ProcessFactory = @MainActor (
        _ executableURL: URL,
        _ arguments: [String]
    ) throws -> any TerminalParticipantProcess

    private struct Participant {
        let role: CollaborationRole
        let process: any TerminalParticipantProcess
        let sink: FrameSink
        var lastIncomingSequence: UInt64 = 0
        var nextOutgoingSequence: UInt64 = 1
    }

    let sessionID: String
    let tmuxCommand: TmuxSessionCommand

    private let signingKey: SymmetricKey
    private let tmuxExecutableURL: URL
    private let processFactory: ProcessFactory
    private var inviteRegistry = InviteCapabilityRegistry()
    private var participants: [String: Participant] = [:]
    private(set) var activeDriverID: String?

    init(
        sessionID: String,
        tmuxCommand: TmuxSessionCommand,
        signingKey: SymmetricKey,
        tmuxExecutableURL: URL,
        processFactory: @escaping ProcessFactory = { executableURL, arguments in
            POSIXTmuxParticipantProcess(executableURL: executableURL, arguments: arguments)
        }
    ) {
        self.sessionID = sessionID
        self.tmuxCommand = tmuxCommand
        self.signingKey = signingKey
        self.tmuxExecutableURL = tmuxExecutableURL
        self.processFactory = processFactory
    }

    @discardableResult
    func attach(
        token: String,
        participantID: String,
        now: Date = Date(),
        sink: @escaping FrameSink
    ) throws -> CollaborationRole {
        guard Self.isSafeParticipantID(participantID) else {
            throw TerminalHostError.invalidParticipantID
        }
        guard participants[participantID] == nil else {
            throw TerminalHostError.participantAlreadyAttached
        }

        let capability = try InviteCapabilitySigner.verify(token, key: signingKey, now: now)
        guard capability.sessionID == sessionID else { throw TerminalHostError.wrongSession }
        try inviteRegistry.consume(capability, now: now)

        let process = try processFactory(
            tmuxExecutableURL,
            tmuxCommand.participantArguments(role: capability.role)
        )
        process.onOutput = { [weak self] data in
            self?.publishOutput(data, participantID: participantID)
        }
        process.onExit = { [weak self] status in
            self?.processExited(status: status, participantID: participantID)
        }

        participants[participantID] = Participant(
            role: capability.role,
            process: process,
            sink: sink
        )
        if capability.role == .driver && activeDriverID == nil {
            activeDriverID = participantID
        }

        do {
            try process.start()
        } catch {
            participants.removeValue(forKey: participantID)
            if activeDriverID == participantID { activeDriverID = nil }
            throw error
        }

        return capability.role
    }

    func receive(_ frame: TerminalFrame, from participantID: String) throws {
        guard var participant = participants[participantID] else {
            throw TerminalHostError.participantNotAttached
        }
        guard frame.sequence > participant.lastIncomingSequence else {
            throw TerminalHostError.staleSequence
        }
        participant.lastIncomingSequence = frame.sequence
        participants[participantID] = participant

        switch frame.type {
        case .input:
            guard participant.role != .viewer, activeDriverID == participantID else {
                throw TerminalHostError.inputDenied
            }
            try participant.process.sendInput(frame.payload)

        case .resize:
            guard participant.role != .viewer, activeDriverID == participantID else {
                throw TerminalHostError.resizeDenied
            }
            let size = try JSONDecoder().decode(TerminalResize.self, from: frame.payload)
            guard size.isValid else { throw TerminalHostError.invalidResize }
            try participant.process.resize(size)

        case .ping:
            send(type: .ping, payload: frame.payload, to: participantID)

        case .hello, .output, .role, .error:
            throw TerminalHostError.unsupportedMessage
        }
    }

    func detach(participantID: String) {
        guard let participant = participants.removeValue(forKey: participantID) else { return }
        participant.process.onOutput = nil
        participant.process.onExit = nil
        participant.process.stop()
        if activeDriverID == participantID { activeDriverID = nil }
    }

    func revokeInvite(nonce: String) {
        inviteRegistry.revoke(nonce: nonce)
    }

    func revokeSession() {
        inviteRegistry.revoke(sessionID: sessionID)
        for participantID in Array(participants.keys) {
            detach(participantID: participantID)
        }
    }

    private func publishOutput(_ data: Data, participantID: String) {
        var offset = 0
        while offset < data.count {
            let end = min(offset + TerminalFrame.maximumPayloadSize, data.count)
            send(type: .output, payload: data.subdata(in: offset..<end), to: participantID)
            offset = end
        }
    }

    private func processExited(status: Int32, participantID: String) {
        let payload = Data("tmux exited with status \(status)".utf8)
        send(type: .error, payload: payload, to: participantID)
        participants.removeValue(forKey: participantID)
        if activeDriverID == participantID { activeDriverID = nil }
    }

    private func send(type: TerminalMessageType, payload: Data, to participantID: String) {
        guard var participant = participants[participantID] else { return }
        guard let frame = try? TerminalFrame(
            type: type,
            sequence: participant.nextOutgoingSequence,
            payload: payload
        ) else { return }

        participant.nextOutgoingSequence += 1
        participants[participantID] = participant
        participant.sink(frame)
    }

    private static func isSafeParticipantID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}
