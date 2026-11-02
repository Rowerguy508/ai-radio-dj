import XCTest
@testable import AeroDJCore

/// Owner decision: Pro gets a 7-day free trial (Fry's intro offer on #244). The trial line is
/// built from the StoreKit product (intro offer + `displayPrice`) and only shown when the
/// product has a free trial and the user is eligible. -Nova
final class PaywallTrialCopyTests: XCTestCase {
    private let week = PaywallIntroOffer(value: 1, unit: .week, isFreeTrial: true)

    func testFreeTrialAndEligibleShowsTheTrialLine() {
        XCTAssertEqual(PaywallCopy.trialLine(.monthly, price: "$4.99", offer: week, eligible: true),
                       "7 days free, then $4.99/month")
    }

    func testYearlyPrice() {
        XCTAssertEqual(PaywallCopy.trialLine(.yearly, price: "$34.99", offer: week, eligible: true),
                       "7 days free, then $34.99/year")
    }

    func testNotEligibleShowsOnlyThePlainPrice() {
        XCTAssertNil(PaywallCopy.trialLine(.monthly, price: "$4.99", offer: week, eligible: false))
        XCTAssertNil(PaywallCopy.trialLine(.yearly, price: "$34.99", offer: week, eligible: false))
        XCTAssertEqual(PaywallCopy.planLine(.monthly, price: "$4.99"), "Monthly, $4.99 per month")
    }

    func testNoOfferShowsOnlyThePlainPrice() {
        XCTAssertNil(PaywallCopy.trialLine(.monthly, price: "$4.99", offer: nil, eligible: true))
        XCTAssertEqual(PaywallCopy.planLine(.yearly, price: "$34.99"), "Yearly, $34.99 per year")
    }

    func testAPaidIntroOfferIsNotAFreeTrial() {
        let payAsYouGo = PaywallIntroOffer(value: 1, unit: .week, isFreeTrial: false)
        XCTAssertNil(PaywallCopy.trialLine(.monthly, price: "$4.99", offer: payAsYouGo, eligible: true))
        XCTAssertNil(PaywallCopy.trialLine(.monthly, price: "$4.99",
                                           offer: PaywallIntroOffer(value: 0, unit: .day, isFreeTrial: true), eligible: true))
    }

    func testThePriceIsPassedThroughLocalized() {
        XCTAssertEqual(PaywallCopy.trialLine(.yearly, price: "34,99 €", offer: week, eligible: true),
                       "7 days free, then 34,99 €/year")
    }

    func testTrialLengths() {
        XCTAssertEqual(PaywallCopy.trialLength(PaywallIntroOffer(value: 3, unit: .day, isFreeTrial: true)), "3 days")
        XCTAssertEqual(PaywallCopy.trialLength(PaywallIntroOffer(value: 1, unit: .day, isFreeTrial: true)), "1 day")
        XCTAssertEqual(PaywallCopy.trialLength(PaywallIntroOffer(value: 2, unit: .week, isFreeTrial: true)), "14 days")
        XCTAssertEqual(PaywallCopy.trialLength(PaywallIntroOffer(value: 1, unit: .month, isFreeTrial: true)), "1 month")
        XCTAssertEqual(PaywallCopy.trialLength(PaywallIntroOffer(value: 1, unit: .year, isFreeTrial: true)), "1 year")
    }

    // MARK: App call site (iOS-only target; the scan fails if the view stops using the product)

    private func appPaywall() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("ios/AeroDJ/Purchases/Subscriptions+App.swift"),
                          encoding: .utf8)
    }

    func testThePaywallBuildsTheTrialLineFromTheStoreKitProduct() throws {
        let source = try appPaywall()
        for needle in ["subscription?.introductoryOffer", "intro.paymentMode == .freeTrial", "intro.period.value",
                       "isEligibleForIntroOffer", "PaywallCopy.trialLine(period, price: product.displayPrice",
                       "eligible: introEligible[product.id] ?? false", "model.trialLine(for: product, period: period)",
                       "if let trial {"] {
            XCTAssertTrue(source.contains(needle), "missing: \(needle)")
        }
    }

    func testThePaywallHardCodesNoPrices() throws {
        let code = try appPaywall().split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for price in ["4.99", "34.99", "\"$", "7 days", "/month\"", "/year\""] {
            XCTAssertFalse(code.contains(price), "hard-coded in the view: \(price)")
        }
    }
}
