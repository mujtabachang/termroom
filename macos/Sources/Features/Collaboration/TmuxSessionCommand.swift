import Foundation

enum TmuxSessionCommandError: Error, Equatable {
    case invalidSocketName
    case invalidSessionName
}

/// Builds tmux argument arrays without involving a shell. Session and socket identifiers are
/// deliberately restricted because they originate in invite/session metadata.
struct TmuxSessionCommand: Equatable {
    let socketName: String
    let sessionName: String

    init(socketName: String, sessionName: String) throws {
        guard Self.isSafeIdentifier(socketName) else {
            throw TmuxSessionCommandError.invalidSocketName
        }
        guard Self.isSafeIdentifier(sessionName) else {
            throw TmuxSessionCommandError.invalidSessionName
        }

        self.socketName = socketName
        self.sessionName = sessionName
    }

    /// Starts the private session when needed, otherwise attaches to the existing session.
    var hostArguments: [String] {
        ["-L", socketName, "new-session", "-A", "-s", sessionName]
    }

    /// Returns arguments for a distinct tmux client PTY. Only the active driver can affect the
    /// canonical tmux size; viewer input is additionally rejected by tmux itself.
    func participantArguments(role: CollaborationRole) -> [String] {
        var result = ["-L", socketName, "attach-session"]

        switch role {
        case .driver:
            break
        case .collaborator:
            result.append(contentsOf: ["-f", "ignore-size"])
        case .viewer:
            result.append("-r")
        }

        result.append(contentsOf: ["-t", "=\(sessionName)"])
        return result
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}
