import Foundation
import OSLog
import WebKit

struct PlayroomBridgeSnapshot: Decodable, Equatable {
    struct Participant: Decodable, Equatable {
        let id: String
        let displayName: String
        let avatarInitials: String
        let accentRGB: UInt32
        let role: CollaborationRole
        let cursor: CollaborationCursor?
    }

    let roomCode: String
    let localParticipantID: String
    let participants: [Participant]
}

/// Hosts Playroom's JavaScript SDK in an isolated web view and exposes only typed presence data to
/// the native UI. Terminal input and output never pass through this bridge.
final class PlayroomBridge: NSObject, CollaborationTransport {
    static let shared = PlayroomBridge()
    static let gameID = "UfwDzoiAKT4iKN1EwnrY"
    static let sdkVersion = "0.0.97"

    private static let messageHandlerName = "termroom"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.termroom.app",
        category: String(describing: PlayroomBridge.self)
    )

    private let session: CollaborationSessionStore
    private var webView: WKWebView?

    private init(session: CollaborationSessionStore = .shared) {
        self.session = session
        super.init()
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageHandlerName
        )
    }

    /// Starts a new Playroom room when `roomCode` is nil, or joins the supplied room.
    func start(roomCode: String?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard webView == nil else { return }
        session.setConnectionState(.connecting)

        let controller = WKUserContentController()
        controller.add(self, name: Self.messageHandlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        self.webView = webView
        session.transport = self
        webView.loadHTMLString(
            Self.bridgeHTML(roomCode: roomCode),
            baseURL: URL(string: "https://cdn.jsdelivr.net/")
        )
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        tearDownWebView()
        session.replaceSession(roomCode: nil, localParticipantID: nil, participants: [])
        session.setConnectionState(.disconnected)
    }

    private func tearDownWebView() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageHandlerName
        )
        webView = nil
        session.transport = nil
    }

    func sendCursor(_ cursor: CollaborationCursor?) {
        guard let webView else { return }

        let value: Any
        if let cursor {
            value = ["x": cursor.x, "y": cursor.y]
        } else {
            value = NSNull()
        }

        guard
            let data = try? JSONSerialization.data(withJSONObject: value),
            let json = String(data: data, encoding: .utf8)
        else { return }

        webView.evaluateJavaScript("window.termroomBridge?.sendCursor(\(json))") { _, error in
            if let error {
                Self.logger.error("Failed to publish Playroom cursor: \(error.localizedDescription)")
            }
        }
    }

    private func apply(_ snapshot: PlayroomBridgeSnapshot) {
        let participants = snapshot.participants.map { participant in
            CollaborationParticipant(
                id: participant.id,
                displayName: participant.displayName,
                avatarInitials: participant.avatarInitials,
                accentRGB: participant.accentRGB,
                role: participant.role,
                cursor: participant.cursor
            )
        }

        session.replaceSession(
            roomCode: snapshot.roomCode,
            localParticipantID: snapshot.localParticipantID,
            participants: participants
        )
        session.setConnectionState(.connected)
    }

    private static func bridgeHTML(roomCode: String?) -> String {
        var options: [String: Any] = [
            "gameId": gameID,
            "baseUrl": "https://joinplayroom.com/",
            "skipLobby": true,
            "maxPlayersPerRoom": 8,
            "reconnectGracePeriod": 15_000,
        ]
        if let roomCode, !roomCode.isEmpty {
            options["roomCode"] = roomCode
        }

        let optionsData = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])
        let optionsJSON = optionsData.map { String(decoding: $0, as: UTF8.self) } ?? "{}"

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy"
                content="default-src 'none';
                         script-src 'nonce-termroom-bridge' https://cdn.jsdelivr.net;
                         connect-src https://cdn.jsdelivr.net https://*.joinplayroom.com
                                     wss://*.joinplayroom.com https://api-js.mixpanel.com
                                     https://cdn.mxpnl.com;
                         img-src data: https:;
                         style-src 'unsafe-inline'; worker-src blob:">
        </head>
        <body>
        <script type="module" nonce="termroom-bridge">
          import {
            getParticipants,
            getRoomCode,
            insertCoin,
            isHost,
            myPlayer,
            onDisconnect
          } from "https://cdn.jsdelivr.net/npm/playroomkit@\(sdkVersion)/+esm";

          const post = (type, payload = {}) => {
            window.webkit.messageHandlers.\(messageHandlerName).postMessage({ type, payload });
          };

          const options = \(optionsJSON);
          let lastSnapshot = "";

          const initials = (name) => {
            const parts = String(name || "Guest").trim().split(/\\s+/).filter(Boolean);
            return parts.slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "GU";
          };

          const accentRGB = (profile) => {
            if (Number.isFinite(profile?.color?.hex)) return profile.color.hex;
            const value = String(profile?.color?.hexString || "7C3AED").replace("#", "");
            const parsed = Number.parseInt(value, 16);
            return Number.isFinite(parsed) ? parsed : 0x7C3AED;
          };

          const snapshot = () => {
            const local = myPlayer();
            if (!local) return;

            const records = Object.values(getParticipants() || {});
            if (!records.some((player) => player.id === local.id)) records.push(local);

            const participants = records.map((player) => {
              const profile = player.getProfile?.() || {};
              const name = String(profile.name || "Guest").slice(0, 64);
              return {
                id: player.id,
                displayName: name,
                avatarInitials: initials(name),
                accentRGB: accentRGB(profile),
                role: player.getState("termroom.role") || "collaborator",
                cursor: player.getState("termroom.cursor") || null
              };
            });

            const payload = {
              roomCode: getRoomCode() || "",
              localParticipantID: local.id,
              participants
            };
            const encoded = JSON.stringify(payload);
            if (encoded !== lastSnapshot) {
              lastSnapshot = encoded;
              post("snapshot", payload);
            }
          };

          window.termroomBridge = {
            sendCursor(cursor) {
              myPlayer()?.setState("termroom.cursor", cursor, false);
            }
          };

          try {
            await insertCoin(options);
            const local = myPlayer();
            local.setState("termroom.role", isHost() ? "driver" : "collaborator", true);
            onDisconnect((event) => post("disconnected", event || {}));
            snapshot();
            window.setInterval(snapshot, 50);
            post("ready", { roomCode: getRoomCode() || "" });
          } catch (error) {
            post("error", { message: String(error?.message || error) });
          }
        </script>
        </body>
        </html>
        """
    }
}

extension PlayroomBridge: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard
            message.name == Self.messageHandlerName,
            let envelope = message.body as? [String: Any],
            let type = envelope["type"] as? String
        else { return }

        switch type {
        case "snapshot":
            guard
                let payload = envelope["payload"],
                JSONSerialization.isValidJSONObject(payload),
                let data = try? JSONSerialization.data(withJSONObject: payload),
                let snapshot = try? JSONDecoder().decode(PlayroomBridgeSnapshot.self, from: data)
            else {
                Self.logger.error("Received an invalid Playroom snapshot")
                return
            }
            apply(snapshot)

        case "ready":
            Self.logger.info("Playroom bridge is ready")

        case "disconnected":
            Self.logger.warning("Playroom bridge disconnected")
            session.setConnectionState(.disconnected)

        case "error":
            let payload = envelope["payload"] as? [String: Any]
            let detail = payload?["message"] as? String ?? "Unknown error"
            Self.logger.error("Playroom bridge error: \(detail)")
            tearDownWebView()
            session.replaceSession(roomCode: nil, localParticipantID: nil, participants: [])
            session.setConnectionState(.failed(detail))

        default:
            Self.logger.debug("Ignoring unknown Playroom message: \(type)")
        }
    }
}

extension PlayroomBridge: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let allowedHosts = ["cdn.jsdelivr.net", "joinplayroom.com"]
        let hostAllowed = url.host.map { host in
            allowedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
        } ?? false
        let allowed = url.scheme == "about" || hostAllowed
        decisionHandler(allowed ? .allow : .cancel)
    }
}
