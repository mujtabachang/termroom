import Testing
@testable import Ghostty

struct TmuxSessionCommandTests {
    @Test func buildsHostCreateOrAttachArguments() throws {
        let command = try TmuxSessionCommand(
            socketName: "termroom-7f2d",
            sessionName: "room-ABCD1234"
        )

        #expect(command.hostArguments == [
            "-L", "termroom-7f2d", "new-session", "-A", "-s", "room-ABCD1234",
        ])
    }

    @Test func buildsDriverArguments() throws {
        let command = try TmuxSessionCommand(socketName: "termroom", sessionName: "room-1")

        #expect(command.participantArguments(role: .driver) == [
            "-L", "termroom", "attach-session", "-t", "=room-1",
        ])
    }

    @Test func collaboratorCannotResizeCanonicalSession() throws {
        let command = try TmuxSessionCommand(socketName: "termroom", sessionName: "room-1")

        #expect(command.participantArguments(role: .collaborator) == [
            "-L", "termroom", "attach-session", "-f", "ignore-size", "-t", "=room-1",
        ])
    }

    @Test func viewerIsReadOnlyAndCannotResizeCanonicalSession() throws {
        let command = try TmuxSessionCommand(socketName: "termroom", sessionName: "room-1")

        #expect(command.participantArguments(role: .viewer) == [
            "-L", "termroom", "attach-session", "-r", "-t", "=room-1",
        ])
    }

    @Test func rejectsIdentifiersThatCouldReachTmuxOptionParsing() {
        #expect(throws: TmuxSessionCommandError.invalidSessionName) {
            try TmuxSessionCommand(socketName: "termroom", sessionName: "-L attacker")
        }
        #expect(throws: TmuxSessionCommandError.invalidSocketName) {
            try TmuxSessionCommand(socketName: "../../shared", sessionName: "room-1")
        }
    }
}
