import Foundation
import Testing
@testable import Ghostty

struct PlayroomBridgeTests {
    @Test func decodesSnapshotContract() throws {
        let data = try #require("""
        {
          "roomCode": "ABCD1234",
          "localParticipantID": "player-1",
          "participants": [
            {
              "id": "player-1",
              "displayName": "Ahmed Mujtaba",
              "avatarInitials": "AM",
              "accentRGB": 8133357,
              "role": "driver",
              "cursor": { "x": 0.25, "y": 0.75 }
            },
            {
              "id": "player-2",
              "displayName": "Sam",
              "avatarInitials": "SA",
              "accentRGB": 16347926,
              "role": "viewer",
              "cursor": null
            }
          ]
        }
        """.data(using: .utf8))

        let snapshot = try JSONDecoder().decode(PlayroomBridgeSnapshot.self, from: data)

        #expect(snapshot.roomCode == "ABCD1234")
        #expect(snapshot.localParticipantID == "player-1")
        #expect(snapshot.participants.count == 2)
        #expect(snapshot.participants[0].role == .driver)
        #expect(snapshot.participants[0].cursor == CollaborationCursor(x: 0.25, y: 0.75))
        #expect(snapshot.participants[1].role == .viewer)
        #expect(snapshot.participants[1].cursor == nil)
    }

    @Test func pinsPlayroomProjectAndSDKVersion() {
        #expect(PlayroomBridge.gameID == "UfwDzoiAKT4iKN1EwnrY")
        #expect(PlayroomBridge.sdkVersion == "0.0.97")
    }

    @Test func clampsUntrustedRemoteCursorCoordinates() throws {
        let data = try #require("{\"x\":-4,\"y\":12}".data(using: .utf8))
        let cursor = try JSONDecoder().decode(CollaborationCursor.self, from: data)

        #expect(cursor == CollaborationCursor(x: 0, y: 1))
    }

    @Test func treatsUnknownRemoteRoleAsViewer() throws {
        let data = try #require("\"owner\"".data(using: .utf8))
        let role = try JSONDecoder().decode(CollaborationRole.self, from: data)

        #expect(role == .viewer)
    }
}
