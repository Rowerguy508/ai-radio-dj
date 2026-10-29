import XCTest
@testable import AeroDJCore

// Sentinel's #157 follow-up (-Atlas): only plain ASCII-digit genre IDs may be put into the
// catalog `genres/<id>` URL path. `MusicCatalogSeedSource` returns no songs for anything else.
final class StationSeedGenreIDTests: XCTestCase {
    func testASCIIDigitGenreIDsAreAccepted() {
        for id in ["0", "7", "14", "1153", "000123", "9876543210"] {
            XCTAssertTrue(StationSeed.isValidCatalogGenreID(id), id)
        }
    }

    func testEmptyGenreIDIsRejected() {
        XCTAssertFalse(StationSeed.isValidCatalogGenreID(""))
    }

    func testSignedGenreIDsAreRejected() {
        for id in ["-1", "-14", "+14", "1-4"] {
            XCTAssertFalse(StationSeed.isValidCatalogGenreID(id), id)
        }
    }

    func testWhitespaceInOrAroundGenreIDIsRejected() {
        for id in [" ", " 14", "14 ", "1 4", "\t14", "14\n", "\u{00A0}14"] {
            XCTAssertFalse(StationSeed.isValidCatalogGenreID(id), id.debugDescription)
        }
    }

    func testPathAndQueryCharactersAreRejected() {
        for id in ["../x", "..", "./14", "12/34", "/14", "14/", "12?x", "14#x", "14&l=en", "14%2F15", "1.4", "x", "14a", "0x1F"] {
            XCTAssertFalse(StationSeed.isValidCatalogGenreID(id), id)
        }
    }

    func testNonASCIIDigitsAreRejected() {
        // Arabic-Indic, Devanagari, fullwidth and superscript digits all count as "numbers" in Unicode.
        for id in ["١٢", "१२", "１２", "²", "1٢"] {
            XCTAssertFalse(StationSeed.isValidCatalogGenreID(id), id)
        }
    }
}
