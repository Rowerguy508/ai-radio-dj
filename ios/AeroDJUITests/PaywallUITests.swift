import XCTest

/// The paywall sheet (Debug, `-AeroDJShowPaywall`): app name from the constant, a neutral price
/// state, restore, manage, disclosures, and Dynamic Type at accessibility sizes. Prices come from
/// StoreKit (`Product.displayPrice`), so the test accepts loading, unavailable or loaded plans. -Nova
final class PaywallUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJShowPaywall", "YES"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    @MainActor
    func testPaywallShowsTheAppNameAndEveryRequiredControl() {
        let app = launch()
        XCTAssertTrue(element(app, "paywall.sheet").waitForExistence(timeout: 15), "paywall did not appear")
        XCTAssertEqual(element(app, "paywall.title").label, "OnAirly Pro")
        XCTAssertFalse(element(app, "paywall.title").label.contains("AeroDJ"))
        let priceState = ["paywall.loading", "paywall.unavailable", "paywall.plan.yearly", "paywall.plan.monthly"]
        XCTAssertTrue(priceState.contains { element(app, $0).waitForExistence(timeout: 10) }, "no price state")
        for id in ["paywall.restore", "paywall.manage", "paywall.notNow", "paywall.disclosure", "paywall.terms"] {
            let control = element(app, id)
            if !control.exists { app.swipeUp() }
            XCTAssertTrue(control.waitForExistence(timeout: 5), "\(id) missing")
        }
        XCTAssertTrue(element(app, "paywall.disclosure").label.contains("renews automatically"))
    }

    @MainActor
    func testNotNowClosesThePaywall() {
        let app = launch()
        XCTAssertTrue(element(app, "paywall.sheet").waitForExistence(timeout: 15))
        let notNow = element(app, "paywall.notNow")
        if !notNow.isHittable { app.swipeUp() }
        notNow.tap()
        XCTAssertTrue(element(app, "paywall.sheet").waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testPaywallFitsAccessibilityTextSizes() {
        let app = launch(largeText: true)
        XCTAssertTrue(element(app, "paywall.title").waitForExistence(timeout: 15))
        let restore = element(app, "paywall.restore")
        for _ in 0..<4 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.isHittable, "Restore must stay reachable at accessibility sizes")
    }
}
