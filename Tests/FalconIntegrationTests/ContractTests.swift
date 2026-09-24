import Foundation
import Testing
@testable import FalconCore

@Test func retentionIsSevenRollingDays() {
    let summary = RequestSummary(sourceID: UUID(), keyID: UUID(), sourceName: "Fixture", profileID: UUID(), profileName: "Fixture", receivedAt: Date(timeIntervalSince1970: 0))
    #expect(summary.expiresAt.timeIntervalSince1970 == 604_800)
}
