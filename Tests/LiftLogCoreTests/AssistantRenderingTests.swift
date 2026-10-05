import XCTest
@testable import LiftLogCore

final class AssistantRenderingTests: XCTestCase {
    func testScreenshotReplyRendersBoldAndWorkoutBullets() throws {
        let blocks = AssistantMarkdown.parse("""
        Your training volume chart is ready, covering all recorded workouts in **lb**:

        - **Morning Workout:** 6,457.5 lb — Oct 3, 2026
        - **Upper Body:** 3,040 lb — Oct 4, 2026

        Total recorded volume: **9,497.5 lb**
        """)
        XCTAssertEqual(blocks.count, 3)
        guard case .paragraph(let intro) = blocks[0], case .list(let items) = blocks[1] else { return XCTFail("Expected paragraph and semantic list") }
        XCTAssertFalse(String(intro.characters).contains("**"))
        XCTAssertTrue(intro.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertEqual(items.count, 2)
        guard case .paragraph(let first) = items[0].blocks[0] else { return XCTFail("Expected a list paragraph") }
        XCTAssertEqual(String(first.characters), "Morning Workout: 6,457.5 lb — Oct 3, 2026")
    }

    func testNestedListsNumberingAndCombinedInlineStyles() throws {
        let blocks = AssistantMarkdown.parse("""
        ### Progress
        3. ***Strong emphasis*** and `lb × reps`
           - Nested item
        4. Next item
        """)
        guard case .heading(level: 3, _) = blocks[0], case .list(let items) = blocks[1],
              case .paragraph(let text) = items[0].blocks[0], case .list(let nested) = items[0].blocks[1] else {
            return XCTFail("Expected heading and nested list")
        }
        XCTAssertEqual(items.map(\.marker), ["3.", "4."])
        XCTAssertEqual(nested[0].marker, "•")
        XCTAssertTrue(text.runs.contains {
            $0.inlinePresentationIntent?.contains([.emphasized, .stronglyEmphasized]) == true
        })
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    func testTablesQuotesAndCodePreserveContent() {
        let blocks = AssistantMarkdown.parse("""
        | Workout | Volume |
        | --- | ---: |
        | **Upper body** | 3,040 lb |

        > Based on completed sets only.

        ```swift
        let volume = weight * reps
        ```

        ---
        """)
        guard case .table(let header, let rows) = blocks[0], case .quote(let quote) = blocks[1],
              case .code(let language, let code) = blocks[2], case .divider = blocks[3] else {
            return XCTFail("Expected native table, quote, code, and divider")
        }
        XCTAssertEqual(header.map { String($0.characters) }, ["Workout", "Volume"])
        XCTAssertEqual(String(rows[0][0].characters), "Upper body")
        XCTAssertEqual(quote.count, 1)
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let volume = weight * reps\n")
    }

    func testStreamingUnclosedMarkdownPreservesText() {
        for source in ["A **partial reply", "- First item\n- Second", "```swift\nlet value = 4"] {
            XCTAssertFalse(AssistantMarkdown.parse(source).isEmpty)
        }
        guard case .code(_, let code) = AssistantMarkdown.parse("```swift\nlet value = 4")[0] else {
            return XCTFail("Expected an unfinished fence to render as code")
        }
        XCTAssertTrue(code.contains("let value = 4"))
    }

    func testLinksEscapesAndImagesRenderWithoutRemoteContent() {
        let blocks = AssistantMarkdown.parse("[History](https://example.com/history) \\*literal\\* ![Progress](https://example.com/chart.png) [Unsafe](file:///tmp/example)")
        guard case .paragraph(let text) = blocks[0] else { return XCTFail("Expected paragraph") }
        XCTAssertEqual(String(text.characters), "History *literal* Progress Unsafe")
        XCTAssertEqual(text.runs.compactMap(\.link), [URL(string: "https://example.com/history")!])
    }

    func testChartRangeUsesSnapshotLatestDateAndKeepsUnits() {
        let points = [point(day: 0), point(day: 40), point(day: 100)]
        let presentation = AssistantChartPresentation(chart: chart(points.reversed()), range: .month)
        XCTAssertEqual(presentation.points.map(\.id), [points[2].id])
        XCTAssertEqual(presentation.valueUnit, "lb × reps")
        XCTAssertEqual(presentation.formattedValue(6457.5), 6457.5.formatted(.number.precision(.fractionLength(0...2))))
        XCTAssertEqual(AssistantChartPresentation(chart: chart(points), range: .quarter).points.count, 2)
    }

    func testChartSelectionHandlesSparseDuplicateDatesAndBounds() {
        let first = point(day: 1)
        let second = point(day: 1)
        let third = point(day: 2)
        let presentation = AssistantChartPresentation(chart: chart([third, first, second]))
        XCTAssertEqual(presentation.points.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(presentation.axisIndices, [0, 1, 2])
        XCTAssertEqual(presentation.nearestPoint(to: -100)?.id, first.id)
        XCTAssertEqual(presentation.nearestPoint(to: 0.8)?.id, second.id)
        XCTAssertEqual(presentation.nearestPoint(to: 100)?.id, third.id)
        XCTAssertNil(presentation.nearestPoint(to: .nan))
        XCTAssertEqual(AssistantChartPresentation(chart: chart((0..<20).map { point(day: $0) })).axisIndices, [0, 9, 19])
    }

    func testEmptyAndSinglePointCharts() {
        let empty = AssistantChartPresentation(chart: chart([]))
        XCTAssertEqual(empty.axisIndices, [])
        XCTAssertNil(empty.nearestPoint(to: 0))
        let single = point(day: 0, value: 0)
        let presentation = AssistantChartPresentation(chart: chart([single]))
        XCTAssertEqual(presentation.axisIndices, [0])
        XCTAssertEqual(presentation.nearestPoint(to: 100)?.value, 0)
    }

    private func point(day: Int, value: Double = 1080) -> WorkoutAgentChart.Point {
        .init(id: UUID(), date: Date(timeIntervalSince1970: Double(day) * 86400), value: value, workoutName: "Workout \(day)")
    }

    private func chart(_ points: [WorkoutAgentChart.Point]) -> WorkoutAgentChart {
        .init(id: UUID(), title: "Completed volume", metric: .volume, unit: .lb, points: points)
    }
}
