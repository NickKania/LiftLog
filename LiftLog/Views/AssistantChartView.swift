import SwiftUI
import Charts
import UIKit

struct AssistantChartView: View {
    let chart: WorkoutAgentChart
    @State private var range = AssistantChartPresentation.Range.all
    @State private var style = AssistantChartPlot.Style.line
    @State private var selectedID: UUID?
    @State private var selectedPosition: Double?
    @State private var showWorkouts = false
    @State private var shareImage: UIImage?

    private var presentation: AssistantChartPresentation { .init(chart: chart, range: range) }
    private var selectedPoint: WorkoutAgentChart.Point? {
        presentation.points.first { $0.id == selectedID } ?? presentation.points.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if chart.points.isEmpty {
                ContentUnavailableView("No recorded sets", systemImage: "chart.xyaxis.line",
                    description: Text("Complete and save a workout to chart this metric."))
            } else {
                controls
                if let selectedPoint { detail(selectedPoint) }
                AssistantChartPlot(presentation: presentation, style: style, selectedID: selectedPoint?.id)
                    .chartXSelection(value: $selectedPosition)
                    .chartGesture { proxy in
                        SpatialTapGesture().onEnded { value in
                            proxy.selectXValue(at: value.location.x)
                        }.simultaneously(with:
                            LongPressGesture(minimumDuration: 0.25)
                                .sequenced(before: DragGesture(minimumDistance: 0))
                                .onChanged { value in
                                    if case .second(true, let drag?) = value {
                                        proxy.selectXValue(at: drag.location.x)
                                    }
                                }
                        )
                    }
                    .onChange(of: selectedPosition) { _, position in
                        if let position, let point = presentation.nearestPoint(to: position) { selectedID = point.id }
                    }
                HStack(spacing: 6) {
                    Image(systemName: "hand.draw").accessibilityHidden(true)
                    Text("Tap or hold and drag · One point per workout")
                }.font(.caption2).foregroundStyle(.secondary)
                Divider()
                footer
                workoutList
            }
        }.assistantCard()
            .task(id: exportID) { renderShareImage() }
            .onChange(of: range) { _, _ in
                selectedID = nil
                selectedPosition = nil
            }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("WORKOUT HISTORY").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                Text(chart.title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            Image(systemName: "chart.xyaxis.line")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                .padding(9).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                rangePicker
                Spacer(minLength: 12)
                stylePicker
            }
            VStack(alignment: .leading, spacing: 10) {
                rangePicker
                stylePicker
            }
        }
    }

    private var rangePicker: some View {
        Picker("Chart range", selection: $range) {
            ForEach(AssistantChartPresentation.Range.allCases, id: \.self) { range in
                Text(range.label).tag(range)
            }
        }.pickerStyle(.segmented)
            .accessibilityHint("Days ending at the latest recorded workout in this chart")
            .accessibilityIdentifier("assistantChartRangePicker")
    }

    private var stylePicker: some View {
        Menu {
            Picker("Chart style", selection: $style) {
                Label("Line", systemImage: "chart.xyaxis.line").tag(AssistantChartPlot.Style.line)
                Label("Bars", systemImage: "chart.bar.fill").tag(AssistantChartPlot.Style.bars)
            }
        } label: {
            Image(systemName: style == .line ? "chart.xyaxis.line" : "chart.bar.fill")
                .frame(width: 44, height: 36)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel("Chart style")
            .accessibilityValue(style == .line ? "Line" : "Bars")
            .accessibilityIdentifier("assistantChartStyleButton")
    }

    private func detail(_ point: WorkoutAgentChart.Point) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    value(point)
                    Text(presentation.valueUnit).font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    value(point)
                    Text(presentation.valueUnit).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(point.workoutName).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Text(point.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    navigationButton(direction: -1)
                    navigationButton(direction: 1)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private func value(_ point: WorkoutAgentChart.Point) -> some View {
        Text(presentation.formattedValue(point.value))
            .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("assistantChartSelectedValue")
    }

    private func navigationButton(direction: Int) -> some View {
        let points = presentation.points
        let index = points.firstIndex { $0.id == selectedPoint?.id } ?? 0
        let target = index + direction
        return Button {
            selectedID = points[target].id
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.caption.weight(.bold)).frame(width: 44, height: 44)
        }.disabled(!points.indices.contains(target))
            .accessibilityLabel(direction < 0 ? "Previous workout" : "Next workout")
            .accessibilityIdentifier(direction < 0 ? "assistantChartPreviousButton" : "assistantChartNextButton")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source: completed sets in \(presentation.points.count) recorded workouts.")
                .font(.caption).foregroundStyle(.secondary)
            if range != .all {
                Text("\(range.label), ending at this chart’s latest workout.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let shareImage {
                let image = Image(uiImage: shareImage)
                ShareLink(item: image, preview: SharePreview(chart.title, image: image)) {
                    Label("Share chart", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                }.accessibilityIdentifier("assistantShareChartButton")
            }
        }
    }

    private var workoutList: some View {
        let presentation = presentation
        return DisclosureGroup("View workouts (\(presentation.points.count))", isExpanded: $showWorkouts) {
            VStack(spacing: 0) {
                ForEach(presentation.points) { point in
                    Button {
                        selectedID = point.id
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(point.workoutName).foregroundStyle(.primary)
                                Text(point.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(presentation.formattedValue(point.value)).monospacedDigit()
                                Image(systemName: point.id == selectedPoint?.id ? "checkmark.circle.fill" : "circle")
                                    .accessibilityHidden(true)
                            }
                        }.font(.subheadline).padding(.vertical, 12)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(point.workoutName), \(point.date.formatted(date: .abbreviated, time: .shortened)), \(presentation.formattedValue(point.value)) \(presentation.valueUnit)")
                        .accessibilityAddTraits(point.id == selectedPoint?.id ? .isSelected : [])
                    if point.id != presentation.points.last?.id { Divider() }
                }
            }.padding(.top, 6)
        }.font(.subheadline)
            .accessibilityIdentifier("assistantChartWorkoutsDisclosure")
    }

    private var exportID: String { "\(chart.id)-\(range.rawValue)-\(style.rawValue)" }

    @MainActor private func renderShareImage() {
        guard !presentation.points.isEmpty else { shareImage = nil; return }
        let export = VStack(alignment: .leading, spacing: 16) {
            Text("LIFT LOG · WORKOUT HISTORY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(chart.title).font(.title2.bold())
            Text(presentation.valueLabel).font(.subheadline).foregroundStyle(.secondary)
            AssistantChartPlot(presentation: presentation, style: style, selectedID: nil)
            Text("Source: completed sets in \(presentation.points.count) recorded workouts.").font(.caption).foregroundStyle(.secondary)
            if range != .all { Text("\(range.label), ending at this chart’s latest workout.").font(.caption).foregroundStyle(.secondary) }
        }.padding(28).frame(width: 600).background(.white)
            .environment(\.colorScheme, .light).environment(\.dynamicTypeSize, .medium)
        let renderer = ImageRenderer(content: export)
        renderer.scale = 2
        shareImage = renderer.uiImage
    }
}
