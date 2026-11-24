import XCTest

final class HostReturnPolicyTests: XCTestCase {
    private let request = Date(timeIntervalSince1970: 10_000)
    private func decide(reported: String? = nil, current: String? = nil, observed: (String, TimeInterval)? = nil,
                        backgrounded: TimeInterval? = nil, after: TimeInterval = 0) -> HostReturnPolicy.Decision {
        HostReturnPolicy.decide(reported: reported, current: current,
                                observed: observed.map { (id: $0.0, at: request.addingTimeInterval($0.1)) },
                                requestedAt: request,
                                backgroundedAt: backgrounded.map { request.addingTimeInterval($0) },
                                now: request.addingTimeInterval(after))
    }

    func testKeyboardReportWins() {
        XCTAssertEqual(decide(reported: "app.muse", current: "app.grok", observed: ("app.grok", -600)), .open("app.muse"))
    }

    func testSameHostAfterSuspensionWaitsThenReturnsCurrent() {
        // Lab was last in front for Notes ten minutes ago and then suspended.
        // Wait briefly for any newer event, then trust the live current state.
        XCTAssertEqual(decide(current: "app.notes", observed: ("app.notes", -600), backgrounded: -600.5), .wait)
        XCTAssertEqual(decide(current: "app.notes", observed: ("app.notes", -600), backgrounded: -600.5, after: 1), .open("app.notes"))
        // If current state is empty, do not fall back to an ancient observed host.
        XCTAssertEqual(decide(current: nil, observed: ("app.grok", -600), backgrounded: -600.5, after: 1), .unknown)
    }

    func testFreshEventForThisVisitIsUsedAtOnce() {
        XCTAssertEqual(decide(current: "app.muse", observed: ("app.muse", 0.2), backgrounded: -600, after: 0.2), .open("app.muse"))
        XCTAssertEqual(decide(current: "app.muse", observed: ("app.muse", -1), backgrounded: -600), .open("app.muse"))
    }

    func testChangedStateWithoutEventIsUsed() {
        XCTAssertEqual(decide(current: "app.muse", observed: ("app.grok", -600), backgrounded: -600.5), .open("app.muse"))
        XCTAssertEqual(decide(current: "app.muse"), .open("app.muse"))
    }

    func testEventsReceivedInBackgroundStayTrusted() {
        // The session was running, so Lab saw the keyboard appear in Muse a minute ago.
        XCTAssertEqual(decide(current: "app.muse", observed: ("app.muse", -60), backgrounded: -600), .wait)
        XCTAssertEqual(decide(current: "app.muse", observed: ("app.muse", -60), backgrounded: -600, after: 1), .open("app.muse"))
    }

    func testColdLaunchHostIsTrustedEvenAfterSlowLaunch() {
        XCTAssertEqual(decide(current: "app.muse", observed: ("app.muse", -5), backgrounded: nil), .open("app.muse"))
        XCTAssertEqual(decide(current: nil, observed: ("app.muse", -5), backgrounded: nil), .open("app.muse"))
    }

    func testNothingKnown() {
        XCTAssertEqual(decide(), .wait)
        XCTAssertEqual(decide(after: 1), .unknown)
    }

    func testBundleIDNormalizesTeamPrefixAndSceneID() {
        XCTAssertEqual(HostBundleID.normalize("com.apple.mobilenotes"), "com.apple.mobilenotes")
        XCTAssertEqual(HostBundleID.normalize("88L2Q4487U.com.tencent.xin"), "com.tencent.xin")
        XCTAssertEqual(HostBundleID.normalize("sceneID:com.apple.mobilenotes-default"), "com.apple.mobilenotes")
        XCTAssertEqual(
            HostBundleID.normalize("FBSSceneIdentity:sceneID%3Acom.my-company.app-7A3B4C5D-1111"),
            "com.my-company.app"
        )
        XCTAssertNil(HostBundleID.normalize("sceneID:com.apple.InputUI-default"))
        XCTAssertNil(HostBundleID.normalize("ABCD123456.org.capswriterlab.keyboard"))
        XCTAssertEqual(HostBundleID.fromAppName("Notes"), "com.apple.mobilenotes")
        XCTAssertEqual(HostBundleID.fromAppName("备忘录"), "com.apple.mobilenotes")
        XCTAssertEqual(HostBundleID.fromAppName("微信"), "com.tencent.xin")
    }
}
