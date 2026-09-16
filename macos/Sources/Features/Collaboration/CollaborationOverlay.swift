import AppKit
import Dispatch
import SwiftUI

/// The collaboration layer deliberately sits above Ghostty's renderer. Terminal bytes continue
/// to flow through Ghostty and tmux while a transport adapter publishes ephemeral presence here.
protocol CollaborationTransport: AnyObject {
    func sendCursor(_ cursor: CollaborationCursor?)
}

struct CollaborationCursor: Equatable {
    /// Coordinates normalized to the terminal surface using a top-left origin.
    let x: Double
    let y: Double
}

enum CollaborationRole: String {
    case driver
    case collaborator
    case viewer
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
    @ObservedObject private var session = CollaborationSessionStore.shared

    var body: some View {
        if session.isActive {
            GeometryReader { geometry in
                ZStack(alignment: .topTrailing) {
                    ForEach(remoteParticipants) { participant in
                        if let cursor = participant.cursor {
                            RemoteCursor(participant: participant)
                                .position(
                                    x: cursor.x * geometry.size.width,
                                    y: cursor.y * geometry.size.height
                                )
                        }
                    }

                    PresenceBadge(participants: session.participants)
                        .padding(10)
                }
                .onChange(of: surfaceView.mouseLocationInSurface) { point in
                    session.sendLocalCursor(point, surfaceSize: geometry.size)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var remoteParticipants: [CollaborationParticipant] {
        session.participants.filter { $0.id != session.localParticipantID }
    }
}

private struct PresenceBadge: View {
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
