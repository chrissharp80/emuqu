@testable import Emuqu
import XCTest

/// The Terms of Use and first-launch disclaimer text.
@MainActor
final class HealthDisclaimerTests: XCTestCase {
    /// Apple's Developer Program License Agreement, section 3.3.3 F(iii):
    /// an app that gives real-time route guidance must carry this notice in
    /// its end-user terms, word for word.
    func testTermsCarryTheRouteGuidanceNoticeVerbatim() {
        XCTAssertEqual(
            HealthDisclaimer.routeGuidanceNotice,
            "YOUR USE OF THIS REAL TIME ROUTE GUIDANCE APPLICATION IS AT YOUR SOLE RISK. LOCATION DATA MAY NOT BE ACCURATE."
        )
        let bodies = HealthDisclaimer.sections.map { $0.body }
        XCTAssertTrue(
            bodies.contains { $0.contains(HealthDisclaimer.routeGuidanceNotice) },
            "The English notice must be in the terms whatever the app language."
        )
    }

    /// The notice sits before the closing assumption-of-risk and age
    /// sections, so accepting the terms covers it.
    func testRouteGuidanceNoticePrecedesTheAgreementSections() throws {
        let bodies = HealthDisclaimer.sections.map { $0.body }
        let notice = try XCTUnwrap(bodies.firstIndex { $0.contains(HealthDisclaimer.routeGuidanceNotice) })
        XCTAssertLessThan(notice, bodies.count - 2)
    }

    /// The revision date moves with the text: it must not predate the
    /// route-guidance notice.
    func testRevisionDateIsNoEarlierThanTheRouteGuidanceNotice() throws {
        let calendar = Calendar(identifier: .gregorian)
        let revised = try XCTUnwrap(calendar.date(from: TermsOfUseView.lastRevisedDate))
        let notice = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)))
        XCTAssertGreaterThanOrEqual(revised, notice)
    }
}
