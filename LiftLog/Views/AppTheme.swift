import SwiftUI

/// Content stays matte; glass is reserved for navigation and actions above it.
enum LiftTheme {
    static var canvas: Color { Color(.systemBackground) }
    static var surface: Color { Color(.secondarySystemBackground) }
    static var insetSurface: Color { Color(.tertiarySystemBackground) }
    static let cardRadius: CGFloat = 24
}

/// Native collections retain their editing, search, swipe and accessibility behavior.
struct LiftList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        List {
            Group { content }
                .listRowBackground(LiftTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .liftCanvas()
    }
}

struct LiftForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            Group { content }
                .listRowBackground(LiftTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .liftCanvas()
    }
}

private struct LiftCanvas: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *), !reduceTransparency {
            content.background(LiftTheme.canvas)
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content.background(LiftTheme.canvas)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

/// Use the system's button styles so focus, disabled states and press effects stay native.
private struct LiftGlassButton: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *), !reduceTransparency {
            if prominent {
                content.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

/// Keep fixed actions above scrolling content without a heavy full-width bar.
private struct LiftActionDock: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.padding(16)
            .background {
                LiftTheme.canvas.ignoresSafeArea(.container, edges: .bottom)
            }
            .overlay(alignment: .top) {
                if !reduceTransparency {
                    LinearGradient(colors: [LiftTheme.canvas.opacity(0), LiftTheme.canvas],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 20)
                        .offset(y: -20)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Custom control groups (such as the Assistant composer) share the same fallback.
private struct LiftGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    let interactive: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(LiftTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.secondary.opacity(0.2)) }
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(interactive), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.secondary.opacity(0.15)) }
        }
    }
}

extension View {
    func liftCanvas() -> some View { modifier(LiftCanvas()) }

    func liftActionDock() -> some View { modifier(LiftActionDock()) }

    func liftGlassButton(prominent: Bool = false) -> some View {
        modifier(LiftGlassButton(prominent: prominent))
    }

    func liftGlassSurface(cornerRadius: CGFloat = LiftTheme.cardRadius, interactive: Bool = true) -> some View {
        modifier(LiftGlassSurface(cornerRadius: cornerRadius, interactive: interactive))
    }

}
