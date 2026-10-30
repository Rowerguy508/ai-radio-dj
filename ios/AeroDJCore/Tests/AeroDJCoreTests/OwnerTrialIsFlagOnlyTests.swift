import Foundation
import XCTest
@testable import AeroDJCore

/// Orion's ruling on #244 (Sentinel has final say): the owner trial access compiles only into
/// owner and TestFlight A/B builds (`AERODJ_OWNER_AB`) and is unreachable in an App Store
/// Release build. (a) is a source scan, (b) a unit test of the unflagged build.
final class OwnerTrialIsFlagOnlyTests: XCTestCase {
    private static let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let flag = "AERODJ_OWNER_AB"
    // Built, so this file is not itself a reference.
    private static let needle = "owner" + "Trial"

    // MARK: (a) source scan

    /// Every line naming the owner trial, comments included, sits in an active
    /// `#if AERODJ_OWNER_AB` branch (or the `#else` of `#if !AERODJ_OWNER_AB`), in every Swift
    /// file of the app, the extension, Core, and their tests.
    func testEveryOwnerTrialReferenceIsGuardedByTheFlag() throws {
        let roots = ["AeroDJ", "AeroDJShare", "AeroDJPhonon", "AeroDJStoreKitTests", "AeroDJUITests",
                     "AeroDJCore/Sources", "AeroDJCore/Tests"].map { Self.ios.appendingPathComponent($0) }
        var references = 0
        var unguarded: [String] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in e where file.pathExtension == "swift" {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, guarded) in Self.guardedLines(lines) where lines[index].contains(Self.needle) {
                    references += 1
                    if !guarded { unguarded.append("\(file.lastPathComponent):\(index + 1)") }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(references, 8, "the scan must see the real references")
        XCTAssertEqual(unguarded, [], "owner trial referenced outside #if \(Self.flag)")
    }

    /// The scanner itself: nesting, `#else`, `#elseif` and the negated form.
    func testGuardScannerFollowsConditionalBlocks() {
        let n = Self.needle
        let lines = ["a \(n)",                          // 0 no
                     "#if \(Self.flag)", "b \(n)",       // 2 yes
                     "#if DEBUG", "c \(n)", "#endif",   // 4 yes (nested)
                     "#else", "d \(n)", "#endif",       // 7 no
                     "#if !\(Self.flag)", "e \(n)",     // 10 no
                     "#else", "f \(n)", "#endif",       // 12 yes
                     "#if DEBUG", "g \(n)",             // 15 no
                     "#elseif \(Self.flag)", "h \(n)", "#endif", // 17 no (conservative)
                     "#if \(Self.flag) // owner", "i \(n)", "#endif"] // 20 yes
        let guarded = Dictionary(uniqueKeysWithValues: Self.guardedLines(lines).map { ($0.0, $0.1) })
        XCTAssertEqual([0, 2, 4, 7, 10, 12, 15, 17, 20].map { guarded[$0]! },
                       [false, true, true, false, false, true, false, false, true])
    }

    /// No checked-in build configuration defines the flag: not project.yml (so not its Release
    /// config), not the xcconfig both configs use, not Package.swift. Only the TestFlight
    /// workflow passes it, on a workflow_dispatch run with owner_ab true
    /// (testflight-swift-conditions.sh, checked by check-owner-ab-build-settings.sh in CI).
    func testNoBuildConfigurationDefinesTheFlag() throws {
        let projectYML = try String(contentsOf: Self.ios.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(projectYML.contains("Release: Config/Signing.xcconfig"), "the Release config this checks")
        XCTAssertFalse(projectYML.contains(Self.flag), "project.yml must not define \(Self.flag) for any config")
        let config = Self.ios.appendingPathComponent("Config")
        let xcconfigs = (try FileManager.default.contentsOfDirectory(at: config, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "xcconfig" }
        XCTAssertFalse(xcconfigs.isEmpty)
        for file in xcconfigs {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(Self.flag), file.lastPathComponent)
        }
        let package = try String(contentsOf: Self.ios.appendingPathComponent("AeroDJCore/Package.swift"), encoding: .utf8)
        XCTAssertFalse(package.contains(Self.flag))
        XCTAssertFalse(package.contains(".define("), "no compile conditions from the package manifest")
    }

    /// Lines of a Swift file paired with whether an enclosing active branch implies the flag.
    static func guardedLines(_ lines: [String]) -> [(Int, Bool)] {
        // Per open #if: (implies the flag when its first branch is active, ... in its #else).
        var stack: [(ifBranch: Bool, elseBranch: Bool, inElse: Bool)] = []
        var out: [(Int, Bool)] = []
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let condition = words.count > 1 ? words[1] : ""
            if line.hasPrefix("#if ") {
                stack.append((condition == flag, condition == "!" + flag, false))
            } else if line.hasPrefix("#elseif "), !stack.isEmpty {
                // Conservative: a branch reached only when an earlier condition failed is not
                // counted as guarded, even if it names the flag.
                stack[stack.count - 1] = (false, false, true)
            } else if line.hasPrefix("#else"), !stack.isEmpty {
                stack[stack.count - 1].inElse = true
            } else if line.hasPrefix("#endif"), !stack.isEmpty {
                stack.removeLast()
            }
            out.append((index, stack.contains { $0.inElse ? $0.elseBranch : $0.ifBranch }))
        }
        return out
    }

    // MARK: (b) without the flag, the gate never returns owner access

    #if !AERODJ_OWNER_AB
    /// Exhaustive with only `.allowed` and `.denied`: if the owner case ever compiled into an
    /// unflagged build, this switch would stop compiling.
    private func isAllowedOrDenied(_ d: ProVoiceGate.Decision) -> Bool {
        switch d {
        case .allowed: return true
        case .denied: return true
        }
    }

    func testWithoutTheFlagTheGateNeverReturnsOwnerAccess() async {
        let id = ProSubscriptionConfig.monthlyProductID
        let epoch = Date(timeIntervalSince1970: 0)
        let states: [ProEntitlementState] = [.free, .pro(productID: id, expiresAt: .distantFuture), .unverified(productID: id),
                                             .expired(productID: id, expiredAt: epoch), .revoked(productID: id, revokedAt: epoch)]
        for state in states {
            for consent in [true, false] {
                let d = ProVoiceGate.decide(entitlement: state, paidVoiceConsent: consent, now: Date())
                XCTAssertTrue(isAllowedOrDenied(d))
                XCTAssertEqual(d == .allowed, consent && state.showsPro, "only Pro + consent, never owner access")
            }
        }
        // What the live app runs with: fail closed, never owner access.
        let live = await ProVoiceAccess.buildDefault.decision()
        XCTAssertEqual(live, .denied(.noConsent))
        XCTAssertFalse(live.permitsPaidVoice)
        // The owner picker preview has no owner access to show.
        XCTAssertEqual(ProVoiceGate.ownerPickerAccess, .denied(.notPro))
        XCTAssertFalse(ProVoiceGate.ownerPickerAccess.permitsPaidVoice)
        // The picker helpers (`PremiumVoicePickerStatus`) are not compiled into this build at all;
        // the Release needle in check-release-disables-paid-voice.sh and ios.yml checks that. -Echo
        // Even forced on, a compose with the picker's access has no owner access.
        let picker = PremiumVoiceRoutes.compose(
            onDevice: [], paidProvidersEnabled: true, access: ProVoiceGate.ownerPickerAccess,
            selectedVoiceID: PremiumVoiceCatalog.voices[0].id,
            credentials: PremiumProxyCredentials(endpoint: URL(string: PremiumVoiceRoutes.defaultEndpoint)!, token: "t"))
        XCTAssertEqual(picker.decision, .omitted(.notEntitled), "even forced on, the picker route has no owner access")
        XCTAssertFalse(OwnerVoiceTrial.paidProvidersEnabled)
    }
    #else
    /// Positive control for the flagged build (check-release-disables-paid-voice.sh compiles the
    /// tests with -DAERODJ_OWNER_AB): there the owner trial is what the app runs with.
    func testOwnerABBuildDefaultsToTheOwnerTrial() async {
        let live = await ProVoiceAccess.buildDefault.decision()
        XCTAssertEqual(live, .ownerTrial)
        XCTAssertEqual(ProVoiceGate.ownerPickerAccess, .ownerTrial)
    }
    #endif
}
