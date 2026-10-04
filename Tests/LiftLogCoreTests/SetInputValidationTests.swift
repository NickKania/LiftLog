import XCTest
@testable import LiftLogCore

final class SetInputValidationTests: XCTestCase {
    func testWeightAcceptsZeroAndFiniteNonnegativeNumbers() {
        for (text, expected) in [("0", 0.0), ("0.0", 0.0), ("135", 135.0),
                                 ("2.5", 2.5), (".5", 0.5), ("135.", 135.0),
                                 ("+5", 5.0), ("1e3", 1000.0)] {
            XCTAssertEqual(SetInputValidation.weight(from: text), expected, text)
        }
    }

    func testWeightAcceptsDecimalCommaIncludingTrailingSeparator() {
        XCTAssertEqual(SetInputValidation.weight(from: "2,5"), 2.5)
        XCTAssertEqual(SetInputValidation.weight(from: ",5"), 0.5)
        XCTAssertEqual(SetInputValidation.weight(from: "135,"), 135)
        XCTAssertNil(SetInputValidation.weight(from: "1,000,5"))
        XCTAssertNil(SetInputValidation.weight(from: "1,2.5"))
    }

    func testWeightRejectsIncompleteAndMalformedInput() {
        for text in ["", ".", ",", "-", "+", "1e", "abc", "1..5", " 5", "5 "] {
            XCTAssertNil(SetInputValidation.weight(from: text), text)
        }
    }

    func testWeightRejectsNegativeAndNonfiniteNumbers() {
        for text in ["-1", "-0.5", "-0,5", "nan", "NaN", "inf", "-inf", "infinity", "1e999"] {
            XCTAssertNil(SetInputValidation.weight(from: text), text)
        }
        // Negative zero satisfies the existing nonnegative-number check.
        XCTAssertEqual(SetInputValidation.weight(from: "-0"), 0)
    }

    func testRepsAcceptsPositiveIntegers() {
        for (text, expected) in [("1", 1), ("12", 12), ("001", 1), ("+5", 5),
                                 (String(Int.max), Int.max)] {
            XCTAssertEqual(SetInputValidation.reps(from: text), expected, text)
        }
    }

    func testRepsRejectsIncompleteNonpositiveNonintegerAndOverflowInput() {
        for text in ["", "+", "-", "0", "-0", "-1", "1.0", "1,0", "1e2", "abc", " 5", "5 ",
                     String(Int.max) + "0"] {
            XCTAssertNil(SetInputValidation.reps(from: text), text)
        }
    }
}
