import SwiftUI

// Design tokens and components. Copied, not linked:
// - workout-companion (ios/Workout/Style.swift, WatchView, ProgramView): the base. Grouped
//   lists, the watch tile, filled number badges, SF Rounded for numbers.
// - Zeron (apps/ios/Zeron/Design/Palette.swift, Cloud/CloudUI.swift): what workout-companion has no use for.
//   Capsule primary/secondary buttons, the welcome layout of the sign-in page, status colors.

extension Color {
    /// CMFX: the TwinDesk theme's accent (Nothing red unless picked in Settings), white on it.
    static var fmcAccent: Color { TDColor.accent }
    static let fmcOnAccent = Color.white
    // Zeron Palette.success / warning / danger
    static let fmcSuccess = Color(light: 0x15803D, dark: 0x34D399)
    static let fmcWarning = Color(light: 0xA16207, dark: 0xFACC15)
    static let fmcDanger = Color(light: 0xDC2626, dark: 0xF87171)

    init(light: UInt32, dark: UInt32) {
        func rgb(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
    }
}

/// A filled rounded square with a symbol or a number in it: the watch tile (64pt, radius 20) and the
/// day badge (44pt, radius 14) of workout-companion.
struct Badge<Content: View>: View {
    var side: CGFloat = 44
    var filled = true
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(filled ? Color.fmcOnAccent : .secondary)
            .frame(width: side, height: side)
            .background(filled ? Color.fmcAccent : Color(.tertiarySystemGroupedBackground),
                        in: .rect(cornerRadius: side * 0.31, style: .continuous))
    }
}

/// A big number with its label under it. (workout-companion Metric)
struct Metric: View {
    let value: String
    let unit: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(.title, design: .rounded, weight: .bold)).monospacedDigit()
            Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Zeron's primary button: a full-width capsule in the accent (fmc.tools .kind__primary), semibold 17, 15/20 insets.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15).padding(.horizontal, 20)
            .foregroundStyle(Color.fmcOnAccent)
            .background(Color.fmcAccent, in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .modifier(Dimmed())
    }
}

/// Zeron's secondary button: a quiet capsule beside or under the primary one (glass on Zeron; a control fill
/// here, as the app also runs on iOS 17).
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14).padding(.horizontal, 20)
            .foregroundStyle(.primary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.15 : 0.075), in: .capsule)
            .modifier(Dimmed())
    }
}

private struct Dimmed: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View { content.opacity(enabled ? 1 : 0.4) }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { .init() }
}
