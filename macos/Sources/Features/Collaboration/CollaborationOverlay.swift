import AppKit
import Dispatch
import SwiftUI

/// The collaboration layer deliberately sits above Ghostty's renderer. Terminal bytes continue
/// to flow through Ghostty and tmux while a transport adapter publishes ephemeral presence here.
protocol CollaborationTransport: AnyObject {
    func sendCursor(_ cursor: CollaborationCursor?)
}

enum CollaborationConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

struct CollaborationCursor: Decodable, Equatable {
    /// Coordinates normalized to the terminal surface using a top-left origin.
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y)
        )
    }

    private enum CodingKeys: CodingKey {
        case x
        case y
    }
}

enum CollaborationRole: String, Decodable {
    case driver
    case collaborator
    case viewer

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .viewer
    }
}

struct CollaborationParticipant: Identifiable, Equatable {
    let id: String
    var displayName: String
    var avatarInitials: String
    var accentRGB: UInt32
    var role: CollaborationRole
    var cursor: CollaborationCursor?

    var accentColor: Color {
        Color(
            red: Double((accentRGB >> 16) & 0xFF) / 255,
            green: Double((accentRGB >> 8) & 0xFF) / 255,
            blue: Double(accentRGB & 0xFF) / 255
        )
    }
}

/// UI-facing session state. A Playroom bridge can populate this store without coupling the
/// terminal renderer to a particular presence provider.
final class CollaborationSessionStore: ObservableObject {
    static let shared = CollaborationSessionStore()

    @Published private(set) var roomCode: String?
    @Published private(set) var localParticipantID: String?
    @Published private(set) var participants: [CollaborationParticipant] = []
    @Published private(set) var connectionState: CollaborationConnectionState = .disconnected

    weak var transport: (any CollaborationTransport)?

    private var lastCursorSendTime: TimeInterval = 0
    private let minimumCursorSendInterval: TimeInterval = 1.0 / 30.0

    var isActive: Bool {
        roomCode != nil
    }

    private init() {
        guard ProcessInfo.processInfo.environment["TERMROOM_DEMO"] == "1" else { return }

        roomCode = "DEMO-ROOM"
        localParticipantID = "local"
        participants = [
            CollaborationParticipant(
                id: "local",
                displayName: "You",
                avatarInitials: "YO",
                accentRGB: 0x7C_3A_ED,
                role: .driver,
                cursor: nil
            ),
            CollaborationParticipant(
                id: "maya",
                displayName: "Maya",
                avatarInitials: "MA",
                accentRGB: 0x06_B6_D4,
                role: .collaborator,
                cursor: .init(x: 0.32, y: 0.38)
            ),
            CollaborationParticipant(
                id: "sam",
                displayName: "Sam",
                avatarInitials: "SA",
                accentRGB: 0xF9_73_16,
                role: .viewer,
                cursor: .init(x: 0.68, y: 0.62)
            ),
        ]
    }

    func replaceSession(
        roomCode: String?,
        localParticipantID: String?,
        participants: [CollaborationParticipant]
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.roomCode = roomCode
        self.localParticipantID = localParticipantID
        self.participants = participants
    }

    func setConnectionState(_ state: CollaborationConnectionState) {
        dispatchPrecondition(condition: .onQueue(.main))
        connectionState = state
    }

    func updateParticipantCursor(id: String, cursor: CollaborationCursor?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let index = participants.firstIndex(where: { $0.id == id }) else { return }
        participants[index].cursor = cursor
    }

    func sendLocalCursor(_ point: CGPoint?, surfaceSize: CGSize) {
        guard isActive, surfaceSize.width > 0, surfaceSize.height > 0 else { return }

        guard let point else {
            transport?.sendCursor(nil)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCursorSendTime >= minimumCursorSendInterval else { return }
        lastCursorSendTime = now

        guard let cursor = Self.normalizedCursor(point, surfaceSize: surfaceSize) else { return }
        transport?.sendCursor(cursor)
    }

    static func normalizedCursor(_ point: CGPoint, surfaceSize: CGSize) -> CollaborationCursor? {
        guard surfaceSize.width > 0, surfaceSize.height > 0 else { return nil }

        // AppKit surfaces use a bottom-left origin. Network cursors use a top-left origin so
        // Playroom/web overlays and SwiftUI renderers agree without platform-specific metadata.
        return CollaborationCursor(
            x: min(max(Double(point.x / surfaceSize.width), 0), 1),
            y: min(max(Double((surfaceSize.height - point.y) / surfaceSize.height), 0), 1)
        )
    }
}

struct CollaborationOverlay: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let showsControls: Bool
    @ObservedObject private var session = CollaborationSessionStore.shared
    @State private var showingSessionSheet = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                if showsControls && session.isActive {
                    ZStack {
                        ForEach(remoteParticipants) { participant in
                            if let cursor = participant.cursor {
                                RemoteCursor(participant: participant)
                                    .position(
                                        x: cursor.x * geometry.size.width,
                                        y: cursor.y * geometry.size.height
                                    )
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                if showsControls {
                    Button {
                        showingSessionSheet = true
                    } label: {
                        if session.isActive {
                            PresenceBadge(
                                roomCode: session.roomCode,
                                participants: session.participants
                            )
                        } else if session.connectionState == .connecting {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                                .background(.ultraThinMaterial, in: Circle())
                        } else {
                            Label("Share", systemImage: "person.2.fill")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .help(session.isActive ? "Manage Termroom session" : "Share this terminal")
                }
            }
            .onChange(of: surfaceView.mouseLocationInSurface) { point in
                guard showsControls else { return }
                session.sendLocalCursor(point, surfaceSize: geometry.size)
            }
        }
        .sheet(isPresented: $showingSessionSheet) {
            CollaborationSessionSheet()
        }
    }

    private var remoteParticipants: [CollaborationParticipant] {
        session.participants.filter { $0.id != session.localParticipantID }
    }
}

private struct CollaborationSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = CollaborationSessionStore.shared
    @State private var joinCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if session.isActive {
                activeSession
            } else if session.connectionState == .connecting {
                connectingSession
            } else {
                startSession
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var connectingSession: some View {
        Group {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connecting to Playroom")
                        .font(.headline)
                    Text("This normally takes a few seconds.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    PlayroomBridge.shared.stop()
                    dismiss()
                }
            }
        }
    }

    private var startSession: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Text("Share this terminal")
                    .font(.title2.bold())
                Text("Create a room or join an existing Termroom session.")
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = session.connectionState {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Button("Create Room") {
                PlayroomBridge.shared.start(roomCode: nil)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(session.connectionState == .connecting)

            HStack {
                Divider()
                Text("or join with a code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Divider()
            }

            TextField("Room code", text: $joinCode)
                .textFieldStyle(.roundedBorder)
                .onSubmit(joinRoom)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Join Room", action: joinRoom)
                    .buttonStyle(.borderedProminent)
                    .disabled(normalizedJoinCode.isEmpty)
            }
        }
    }

    private var activeSession: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Text("Terminal shared")
                    .font(.title2.bold())
                Text("\(session.participants.count) people are connected.")
                    .foregroundStyle(.secondary)
            }

            Text(session.roomCode ?? "")
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)

            HStack {
                Button("Copy Room Code") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(session.roomCode ?? "", forType: .string)
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Leave", role: .destructive) {
                    PlayroomBridge.shared.stop()
                    dismiss()
                }
            }
        }
    }

    private var normalizedJoinCode: String {
        joinCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func joinRoom() {
        guard !normalizedJoinCode.isEmpty else { return }
        PlayroomBridge.shared.start(roomCode: normalizedJoinCode)
        dismiss()
    }
}

private struct PresenceBadge: View {
    let roomCode: String?
    let participants: [CollaborationParticipant]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: -7) {
                ForEach(participants.prefix(4)) { participant in
                    Avatar(participant: participant)
                }
            }

            Label("\(participants.count)", systemImage: "person.2.fill")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            if let roomCode, !roomCode.isEmpty {
                Text(roomCode)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

private struct Avatar: View {
    let participant: CollaborationParticipant

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(participant.accentColor.gradient)
                .frame(width: 27, height: 27)
                .overlay {
                    Text(participant.avatarInitials)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: 1.5))

            if participant.role == .driver {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(participant.accentColor, in: Circle())
                    .overlay(Circle().strokeBorder(.black.opacity(0.45)))
                    .offset(x: 2, y: 2)
            }
        }
    }
}

private struct RemoteCursor: View {
    let participant: CollaborationParticipant

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(participant.accentColor)
                .shadow(color: .black.opacity(0.75), radius: 1)

            Text(participant.displayName)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(participant.accentColor, in: Capsule())
        }
        .fixedSize()
    }
}
