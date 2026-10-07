import SwiftUI
import Charts
import UIKit

struct AssistantChartView: View {
    let chart: WorkoutAgentChart
    @State private var range = AssistantChartPresentation.Range.all
    @State private var style = AssistantChartPlot.Style.line
    @State private var selectedID: UUID?
    @State private var showWorkouts = false
    @State private var shareImage: UIImage?

    private var presentation: AssistantChartPresentation { .init(chart: chart, range: range) }
    private var isHealthChart: Bool { chart.metric.isHealthMetric }
    private var sourceCaption: String {
        isHealthChart
            ? "Source: Apple Health in tagged workout sessions · \(presentation.points.count) time intervals. " + (chart.metric == .heartRate ? "Average heart rate per interval." : "Totals per interval, not per session.")
            : "Source: completed sets in \(presentation.points.count) recorded workouts."
    }
    private var selectedPoint: WorkoutAgentChart.Point? {
        presentation.points.first { $0.id == selectedID } ?? presentation.points.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if chart.points.isEmpty {
                ContentUnavailableView(isHealthChart ? "No available Health readings" : "No recorded sets",
                    systemImage: isHealthChart ? "heart" : "chart.xyaxis.line",
                    description: Text(isHealthChart
                        ? "Apple Health returned no readings for the tagged session. Access may be limited or no readings were recorded."
                        : "Complete and save a workout to chart this metric."))
            } else {
                controls
                if let selectedPoint { detail(selectedPoint) }
                AssistantChartPlot(presentation: presentation, style: style, selectedID: selectedPoint?.id)
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            AssistantChartSelectionOverlay { location in
                                selectPoint(at: location, proxy: proxy, geometry: geometry)
                            }
                                .accessibilityHidden(true)
                        }
                    }
                HStack(spacing: 6) {
                    Image(systemName: "hand.draw").accessibilityHidden(true)
                    Text(isHealthChart ? "Tap or drag sideways · One point per Health interval" : "Tap or drag sideways · One point per workout")
                }.font(.caption2).foregroundStyle(.secondary)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                Divider()
                footer
                workoutList
            }
        }.assistantCard()
            .task(id: exportID) { renderShareImage() }
            .onChange(of: range) { _, _ in
                selectedID = nil
            }
    }

    private func selectPoint(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let frame = proxy.plotFrame else { return }
        let plot = geometry[frame]
        let x = min(max(location.x - plot.minX, 0), plot.width)
        guard let position = proxy.value(atX: x, as: Double.self) else { return }
        let point = isHealthChart
            ? presentation.points.min { abs($0.date.timeIntervalSinceReferenceDate - position) < abs($1.date.timeIntervalSinceReferenceDate - position) }
            : presentation.nearestPoint(to: position)
        selectedID = point?.id
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(isHealthChart ? "APPLE HEALTH · THIS MESSAGE" : "WORKOUT HISTORY").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
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
                if !isHealthChart { rangePicker }
                Spacer(minLength: 12)
                stylePicker
            }
            VStack(alignment: .leading, spacing: 10) {
                if !isHealthChart { rangePicker }
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
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
            .accessibilityLabel(isHealthChart
                ? (direction < 0 ? "Previous Health interval" : "Next Health interval")
                : (direction < 0 ? "Previous workout" : "Next workout"))
            .accessibilityIdentifier(direction < 0 ? "assistantChartPreviousButton" : "assistantChartNextButton")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sourceCaption)
                .font(.caption).foregroundStyle(.secondary)
            if !isHealthChart, range != .all {
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
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var workoutList: some View {
        let presentation = presentation
        return DisclosureGroup(isHealthChart ? "View Health intervals (\(presentation.points.count))" : "View workouts (\(presentation.points.count))", isExpanded: $showWorkouts) {
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
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityIdentifier("assistantChartWorkoutsDisclosure")
    }

    private var exportID: String { "\(chart.id)-\(range.rawValue)-\(style.rawValue)" }

    @MainActor private func renderShareImage() {
        guard !presentation.points.isEmpty else { shareImage = nil; return }
        let export = VStack(alignment: .leading, spacing: 16) {
            Text(isHealthChart ? "LIFT LOG · APPLE HEALTH" : "LIFT LOG · WORKOUT HISTORY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(chart.title).font(.title2.bold())
            Text(presentation.valueLabel).font(.subheadline).foregroundStyle(.secondary)
            AssistantChartPlot(presentation: presentation, style: style, selectedID: nil)
            Text(sourceCaption).font(.caption).foregroundStyle(.secondary)
            if !isHealthChart, range != .all { Text("\(range.label), ending at this chart’s latest workout.").font(.caption).foregroundStyle(.secondary) }
        }.padding(28).frame(width: 600).background(.white)
            .environment(\.colorScheme, .light).environment(\.dynamicTypeSize, .medium)
        let renderer = ImageRenderer(content: export)
        renderer.scale = 2
        shareImage = renderer.uiImage
    }
}

/// Reject vertical pans before recognition so the enclosing transcript can scroll.
/// UIKit's direction check avoids SwiftUI drag recognizers capturing those swipes.
private struct AssistantChartSelectionOverlay: UIViewRepresentable {
    let select: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.inspect(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.inspect(_:)))
        for gesture in [tap, pan] {
            gesture.delegate = context.coordinator
            gesture.cancelsTouchesInView = false
            view.addGestureRecognizer(gesture)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.select = select }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var select: (CGPoint) -> Void
        init(select: @escaping (CGPoint) -> Void) { self.select = select }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func inspect(_ gesture: UIGestureRecognizer) {
            guard [.began, .changed, .ended].contains(gesture.state) else { return }
            select(gesture.location(in: gesture.view))
        }
    }
}
