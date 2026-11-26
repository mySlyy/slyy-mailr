import SwiftUI
import CoreText

/// Slyy look from the wireframes: Hanken Grotesk + Martian Mono, white ground, near-black ink,
/// one blue accent, square corners, 1 px hairlines.
enum Slyy {
    // MARK: Colors
    static let ink = Color(rgb: 0x0A0A0A)
    static let ink2 = Color(rgb: 0x3D3D3D)
    static let muted = Color(rgb: 0x5C5C5C)
    static let line = Color(rgb: 0xE2E2E2)
    static let lineStrong = Color(rgb: 0xA3A3A3)
    static let accent = Color(rgb: 0x2B3BFF)
    static let accentPressed = Color(rgb: 0x1F2ED0)
    static let tint = Color(rgb: 0xE6E8FF)
    static let todayTint = Color(rgb: 0xF7F8FF)
    static let sidebar = Color(rgb: 0xF9F9F7)
    static let panel = Color(rgb: 0xF4F4F2)
    static let danger = Color(rgb: 0xB42318)
    static let leave = Color(rgb: 0xD92D20)
    static let orange = Color(rgb: 0xD9730D)
    static let orangeTint = Color(rgb: 0xFBE4D0)
    static let callBackground = Color(rgb: 0x0A0A0A)

    // MARK: Fonts

    enum Weight { case regular, medium, semibold, bold }

    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .regular: name = "HankenGrotesk-Regular"
        case .medium: name = "HankenGrotesk-Medium"
        case .semibold: name = "HankenGrotesk-SemiBold"
        case .bold: name = "HankenGrotesk-Bold"
        }
        return .custom(name, size: size)
    }

    static func mono(_ size: CGFloat, medium: Bool = false) -> Font {
        .custom(medium ? "MartianMono-Medium" : "MartianMono-Regular", size: size)
    }

    static let body = font(14)
    static let bodyPhone = font(15)

    /// Registers the bundled fonts for this process (macOS and iOS).
    static func registerFonts() {
        let names = ["HankenGrotesk-Regular", "HankenGrotesk-Medium", "HankenGrotesk-SemiBold", "HankenGrotesk-Bold", "MartianMono-Regular", "MartianMono-Medium"]
        for n in names {
            guard let url = Bundle.main.url(forResource: n, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

// MARK: Buttons

/// Black fill, white text (New message, Sign in, selected RSVP).
struct SlyyPrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    var height: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .font(Slyy.font(14, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(configuration.isPressed ? Slyy.ink2 : Slyy.ink)
            .contentShape(Rectangle())
    }
}

/// Blue fill (Send, Join).
struct SlyyAccentButtonStyle: ButtonStyle {
    var fullWidth = false
    var height: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .font(Slyy.font(14, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(configuration.isPressed ? Slyy.accentPressed : Slyy.accent)
            .contentShape(Rectangle())
    }
}

/// White with a hairline (Reply, Archive, Cancel). `strong` uses the darker border (Meet now, Today).
struct SlyyOutlineButtonStyle: ButtonStyle {
    var strong = false
    var fullWidth = false
    var height: CGFloat = 34
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .font(Slyy.font(14, selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Slyy.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(selected ? Slyy.ink : (configuration.isPressed ? Slyy.panel : Color.white))
            .overlay(Rectangle().stroke(selected ? Slyy.ink : (strong ? Slyy.lineStrong : Slyy.line), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Plain row button with a hover/press fill (sidebar items).
struct SlyyRowButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Slyy.line : (configuration.isPressed ? Slyy.panel : Color.clear))
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == SlyyPrimaryButtonStyle {
    static var slyyPrimary: SlyyPrimaryButtonStyle { SlyyPrimaryButtonStyle() }
}

extension ButtonStyle where Self == SlyyAccentButtonStyle {
    static var slyyAccent: SlyyAccentButtonStyle { SlyyAccentButtonStyle() }
}

extension ButtonStyle where Self == SlyyOutlineButtonStyle {
    static var slyyOutline: SlyyOutlineButtonStyle { SlyyOutlineButtonStyle() }
}

// MARK: Fields and toggles

/// Square text field with a grey hairline.
struct SlyyFieldStyle: TextFieldStyle {
    var padding: CGFloat = 10

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(Slyy.body)
            .padding(padding)
            .background(Color.white)
            .overlay(Rectangle().stroke(Slyy.lineStrong, lineWidth: 1))
    }
}

/// Square switch: blue track when on, grey when off.
struct SlyySwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Rectangle().fill(configuration.isOn ? Slyy.accent : Slyy.lineStrong).frame(width: 48, height: 28)
                    Rectangle().fill(Color.white).frame(width: 22, height: 22).padding(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Square checkbox with the accent colour.
struct SlyyCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Rectangle().fill(configuration.isOn ? Slyy.accent : Color.white).frame(width: 16, height: 16)
                        .overlay(Rectangle().stroke(configuration.isOn ? Slyy.accent : Slyy.lineStrong, lineWidth: 1))
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: Small pieces

/// "MAIL", "CALENDARS": 11 pt uppercase, tracked, muted.
struct SectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Slyy.font(11, .medium))
            .tracking(0.66)
            .textCase(.uppercase)
            .foregroundStyle(Slyy.muted)
    }
}

/// Blue dot + "slyy" + muted "mailr".
struct SlyyLogo: View {
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Slyy.accent).frame(width: size * 0.7, height: size * 0.7)
            Text("slyy").font(Slyy.font(size, .bold)).tracking(-0.5).foregroundStyle(Slyy.ink)
                + Text(" mailr").font(Slyy.font(size, .medium)).foregroundStyle(Slyy.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Slyy Mailr")
    }
}

/// "INVITE" tag in mono on blue.
struct MonoTag: View {
    let text: String
    var background: Color = Slyy.accent

    var body: some View {
        Text(text)
            .font(Slyy.mono(10))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(background)
    }
}

/// Round initials avatar.
struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 32

    var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        return parts.compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(Slyy.font(size * 0.38, .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Slyy.ink, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Wireframe icons (stroke SVG paths from the design) drawn as SwiftUI shapes where SF Symbols differ too much.
enum SlyyIcon {
    static let video = "video"
    static let compose = "square.and.pencil"
    static let attach = "paperclip"
    static let doc = "doc"
    static let send = "paperplane.fill"
}

extension View {
    /// Hairline bottom border.
    func bottomHairline() -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(Slyy.line).frame(height: 1) }
    }

    /// Hairline trailing border.
    func trailingHairline() -> some View {
        overlay(alignment: .trailing) { Rectangle().fill(Slyy.line).frame(width: 1) }
    }

    func hairlineBorder(_ color: Color = Slyy.line) -> some View {
        overlay(Rectangle().stroke(color, lineWidth: 1))
    }
}
