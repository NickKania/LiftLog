import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutSummaryStructuredOutputTests: XCTestCase {
    private var response: [String: Any] {
        ["headline": "A steady session with improved bench load.",
         "exerciseFindings": [
            ["exercise": "Bench Press", "finding": "Completed load increased by 10 lb with the same reps.", "verdict": "improved"],
            ["exercise": "Barbell Row", "finding": "Recorded load and reps matched the earlier session.", "verdict": "maintained"]
         ],
         "nextSession": ["Repeat the bench load to confirm the increase.", "Keep the row prescription consistent."],
         "healthNote": "Active energy expended: 200 kcal total, not intake.",
         "limitations": "No historical Health is supplied.",
         "completion": "complete"]
    }

    private func render(_ object: [String: Any]) throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return try WorkoutSummaryStructuredOutput.markdown(fromJSON: json)
    }

    func testFullResponseRendersExactMarkdownWithoutVerdictTokens() throws {
        XCTAssertEqual(try render(response), """
        A steady session with improved bench load.

        - **Bench Press:** Completed load increased by 10 lb with the same reps.
        - **Barbell Row:** Recorded load and reps matched the earlier session.

        **Next session**
        1. Repeat the bench load to confirm the increase.
        2. Keep the row prescription consistent.

        Active energy expended: 200 kcal total, not intake.

        Note: No historical Health is supplied.
        """)
    }

    func testMissingNullAndBlankOptionalParagraphsAreOmitted() throws {
        var object = response
        object.removeValue(forKey: "healthNote")
        object.removeValue(forKey: "limitations")
        let expected = try render(object)
        XCTAssertTrue(expected.hasSuffix("2. Keep the row prescription consistent."))
        XCTAssertFalse(expected.contains("Note:"))
        object["healthNote"] = NSNull()
        object["limitations"] = NSNull()
        XCTAssertEqual(try render(object), expected)
        object["healthNote"] = " \n\t"
        object["limitations"] = "\t "
        XCTAssertEqual(try render(object), expected)
    }

    func testWhitespaceIsTrimmedOnEveryField() throws {
        var padded = response.mapValues { value -> Any in
            if let text = value as? String { return " \n" + text + "\t " }
            return value
        }
        padded["exerciseFindings"] = try XCTUnwrap(response["exerciseFindings"] as? [[String: String]]).map {
            $0.mapValues { " \n" + $0 + "\t " }
        }
        padded["nextSession"] = try XCTUnwrap(response["nextSession"] as? [String]).map { " \n" + $0 + "\t " }
        XCTAssertEqual(try render(padded), try render(response))
    }

    func testInvalidVerdictThrowsInsteadOfRendering() throws {
        for verdict in ["better", "", "IMPROVED"] {
            var object = response
            object["exerciseFindings"] = [["exercise": "Bench Press", "finding": "A recorded finding.", "verdict": verdict]]
            XCTAssertThrowsError(try render(object)) { XCTAssertTrue($0 is AppleFoundationModelsError) }
        }
    }

    func testIncompleteOrMissingCompletionThrows() throws {
        for completion: Any in ["unfinished", NSNull(), false] {
            var object = response
            object["completion"] = completion
            XCTAssertThrowsError(try render(object)) { XCTAssertTrue($0.localizedDescription.contains("did not finish")) }
        }
        var object = response
        object.removeValue(forKey: "completion")
        XCTAssertThrowsError(try render(object))
    }

    func testEmptyRequiredTextThrows() throws {
        var object = response
        object["headline"] = " \n"
        XCTAssertThrowsError(try render(object)) { XCTAssertTrue($0.localizedDescription.contains("empty response")) }
        for field in ["exercise", "finding"] {
            var finding = ["exercise": "Bench Press", "finding": "Recorded finding.", "verdict": "mixed"]
            finding[field] = "\t "
            object = response
            object["exerciseFindings"] = [finding]
            XCTAssertThrowsError(try render(object))
        }
        object = response
        object["nextSession"] = [" \n"]
        XCTAssertThrowsError(try render(object))
    }

    func testFindingAndSuggestionBoundsRejectRatherThanClamp() throws {
        let finding = try XCTUnwrap((response["exerciseFindings"] as? [[String: String]])?.first)
        for count in [0, 13] {
            var object = response
            object["exerciseFindings"] = Array(repeating: finding, count: count)
            XCTAssertThrowsError(try render(object))
        }
        for count in [0, 3] {
            var object = response
            object["nextSession"] = Array(repeating: "Repeat the recorded load.", count: count)
            XCTAssertThrowsError(try render(object))
        }
        var object = response
        object["exerciseFindings"] = Array(repeating: finding, count: 12)
        object["nextSession"] = ["Repeat the recorded load."]
        XCTAssertNoThrow(try render(object))
    }

    func testExpectedVerdictsRejectInventedExercisesAndMismatchedVerdicts() throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        let expected = ["Bench Press": "improved", "Barbell Row": "maintained"]
        XCTAssertNoThrow(try WorkoutSummaryStructuredOutput.markdown(fromJSON: json, expectedVerdicts: expected))
        XCTAssertThrowsError(try WorkoutSummaryStructuredOutput.markdown(fromJSON: json,
            expectedVerdicts: ["Bench Press": "regressed", "Barbell Row": "maintained"]))
        XCTAssertThrowsError(try WorkoutSummaryStructuredOutput.markdown(fromJSON: json,
            expectedVerdicts: ["Bench Press": "improved"]))
    }

    func testMalformedJSONAndWrongFieldTypesThrowProviderErrors() throws {
        for json in ["", "{", "[]", "null", #"{"completion":"complete"}"#] {
            XCTAssertThrowsError(try WorkoutSummaryStructuredOutput.markdown(fromJSON: json)) {
                XCTAssertTrue($0 is AppleFoundationModelsError)
            }
        }
        for field in ["headline", "exerciseFindings", "nextSession", "healthNote", "limitations"] {
            var object = response
            object[field] = 7
            XCTAssertThrowsError(try render(object)) { XCTAssertTrue($0 is AppleFoundationModelsError) }
        }
        var object = response
        object["exerciseFindings"] = [["exercise": "Bench Press", "finding": "Recorded finding."]]
        XCTAssertThrowsError(try render(object))
    }
}
