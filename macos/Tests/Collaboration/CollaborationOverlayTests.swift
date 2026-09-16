import CoreGraphics
import Testing
@testable import Ghostty

struct CollaborationOverlayTests {
    @Test func normalizesAppKitCoordinatesToTopLeftOrigin() throws {
        let cursor = try #require(CollaborationSessionStore.normalizedCursor(
            CGPoint(x: 50, y: 25),
            surfaceSize: CGSize(width: 100, height: 100)
        ))

        #expect(cursor == CollaborationCursor(x: 0.5, y: 0.75))
    }

    @Test func clampsCursorToSurfaceBounds() throws {
        let cursor = try #require(CollaborationSessionStore.normalizedCursor(
            CGPoint(x: 140, y: -20),
            surfaceSize: CGSize(width: 100, height: 100)
        ))

        #expect(cursor == CollaborationCursor(x: 1, y: 1))
    }

    @Test func rejectsEmptySurface() {
        let cursor = CollaborationSessionStore.normalizedCursor(
            CGPoint(x: 0, y: 0),
            surfaceSize: .zero
        )

        #expect(cursor == nil)
    }
}
