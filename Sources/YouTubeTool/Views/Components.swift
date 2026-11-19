import AppKit
import SwiftUI

// MARK: Theme

enum Theme {
    static let accentStart = Color(red: 1.00, green: 0.28, blue: 0.38)
    static let accentEnd = Color(red: 0.98, green: 0.55, blue: 0.22)
    static let accent = LinearGradient(colors: [accentStart, accentEnd], startPoint: .leading, endPoint: .trailing)

    // One colour per meaning.
    static let active = accentStart
    static let success = Color(red: 0.20, green: 0.74, blue: 0.45)
    static let failure = Color(red: 0.92, green: 0.26, blue: 0.24)
    static let neutral = Color.secondary

    // Fixed window / card colours. The system ones (windowBackgroundColor, controlBackgroundColor)
    // differ between macOS versions: on older releases the window is a lighter grey than the
    // cards, so the app looked different on every Mac. These are the macOS 27 values.
    static let windowBackgroundNS = dynamicNS(light: (1, 1, 1), dark: (0.118, 0.118, 0.118))
    static let windowBackground = Color(nsColor: windowBackgroundNS)
    static let cardBackground = windowBackground
    static let cardStroke = Color.primary.opacity(0.07)
    static let chipBackground = Color.primary.opacity(0.07)
    static let radius: CGFloat = 20

    static let windowGradient = LinearGradient(colors: [windowBackground, windowBackground],
                                               startPoint: .top, endPoint: .bottom)

    private static func dynamicNS(light: (Double, Double, Double), dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }
}

/// Rounded card surface: lifted fill with a hairline outline all round.
struct CardSurface: View {
    var radius: CGFloat = Theme.radius

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.cardBackground)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

// MARK: Icons (Iconsax TwoTone)

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let svg = IconsaxSVG.all[name], let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}

struct Icon: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = IconCache.image(name) {
                Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
            } else {
                Image(systemName: "questionmark.square.dashed").resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
    }
}

/// Icon inside a rounded-square chip.
struct IconChip: View {
    let name: String
    var tint: Color = .primary
    var size: CGFloat = 32

    var body: some View {
        Icon(name: name, size: size * 0.56)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(tint.opacity(0.12)))
    }
}

// MARK: Card + labels

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardSurface())
    }
}

/// Section label: small coloured pill + tracked uppercase title.
struct SectionPill: View {
    let text: String
    var color: Color = Theme.accentStart

    var body: some View {
        HStack(spacing: 10) {
            AccentPill(color: color, length: 14)
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
        }
    }
}

/// Short, fully rounded accent pill (detached, never flush against an edge).
struct AccentPill: View {
    var color: Color
    var length: CGFloat = 16
    var vertical = false

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: vertical ? 4 : length, height: vertical ? length : 4)
    }
}

// MARK: Pill picker

struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var icon: ((Value) -> String)? = nil

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = option }
                } label: {
                    HStack(spacing: 6) {
                        if let icon { Icon(name: icon(option), size: 15) }
                        Text(title(option)).font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background {
                        if selected {
                            Capsule().fill(Theme.accent)
                        } else {
                            Capsule().fill(Theme.chipBackground)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: Pill switch

struct PillSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.15)))
                    .frame(width: 40, height: 22)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: Buttons

struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.accent))
            .shadow(color: Theme.accentStart.opacity(isEnabled ? 0.45 : 0), radius: 12, y: 4)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .contentShape(Capsule())
    }
}

/// Round icon-only button used on job cards.
struct IconButton: View {
    let icon: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: 16)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.chipBackground))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: Progress bar

struct GradientProgressBar: View {
    /// nil = indeterminate.
    let fraction: Double?
    var tint: AnyShapeStyle = AnyShapeStyle(Theme.accent)

    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let fraction {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(6, geo.size.width * fraction))
                        .animation(.linear(duration: 0.25), value: fraction)
                } else {
                    Capsule()
                        .fill(tint)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: geo.size.width * phase)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                                phase = 0.7
                            }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}

// MARK: Window chrome

/// Hides a window's title bar and insets the traffic lights the way Safari / Music do:
/// an empty, transparent unified toolbar makes the title bar area taller, and AppKit centres
/// the buttons in it, moving them further from the corner. AppKit keeps them there on
/// resize and full screen, so no manual frame juggling is needed.
@MainActor
enum WindowChrome {
    static func apply(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.windowBackgroundNS
        if window.toolbar?.identifier != "chrome" {
            let toolbar = NSToolbar(identifier: "chrome")
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified

    }
}

struct HiddenTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            WindowChrome.apply(to: window)
            // SwiftUI may install its own toolbar after the first pass; re-apply once it settles.
            DispatchQueue.main.async { [weak window] in
                if let window { WindowChrome.apply(to: window) }
            }
        }
    }
}

