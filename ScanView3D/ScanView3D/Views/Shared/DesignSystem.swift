import SwiftUI

/// Shared visual language. Adaptive library surfaces; opaque, high-contrast field controls.
enum FieldStyle {
    static let accent = Color("AccentColor")
    static let mint = Color(red: 0.43, green: 0.91, blue: 0.78)
    static let ink = Color(red: 0.055, green: 0.10, blue: 0.12)
    static let viewport = Color(red: 0.075, green: 0.105, blue: 0.13)
    static let panel = Color(red: 0.10, green: 0.14, blue: 0.17)
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.045, green: 0.065, blue: 0.08, alpha: 1)
            : UIColor(red: 0.95, green: 0.96, blue: 0.95, alpha: 1)
    })
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let line = Color.primary.opacity(0.08)
}

extension View {
    func fieldScreen() -> some View {
        scrollContentBackground(.hidden)
            .background(FieldStyle.canvas)
            .tint(FieldStyle.accent)
            .toolbarBackground(FieldStyle.canvas, for: .navigationBar)
    }

    func fieldCard() -> some View {
        background(FieldStyle.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(FieldStyle.line, lineWidth: 1))
    }

    func fieldPanel() -> some View {
        background(FieldStyle.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

struct FieldButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .foregroundStyle(prominent ? FieldStyle.ink : .primary)
            .background(prominent ? FieldStyle.mint : FieldStyle.surface,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(FieldStyle.line, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct FieldHero: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let eyebrow: String
    let title: String
    let subtitle: String
    var icon = "viewfinder"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !typeSize.isAccessibilitySize {
            HStack {
                Label(eyebrow.uppercased(), systemImage: icon)
                    .font(.caption.weight(.bold)).tracking(1.6)
                    .foregroundStyle(FieldStyle.mint)
                Spacer(minLength: 0)
                Image(systemName: "circle.hexagongrid")
                    .font(.title2).foregroundStyle(FieldStyle.mint.opacity(0.65))
            }
            }
            Text(title).font(typeSize.isAccessibilitySize ? .headline : .title.weight(.semibold)).tracking(-0.7)
                .fixedSize(horizontal: false, vertical: true)
            if !typeSize.isAccessibilitySize {
            Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(alignment: .trailing) {
            ZStack {
                FieldStyle.ink
                ContourArtwork().foregroundStyle(FieldStyle.mint.opacity(0.09))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Decorative vector contours, not a representation of scan data.
struct ContourArtwork: View {
    var body: some View {
        Canvas { context, size in
            for index in 0..<12 {
                let inset = CGFloat(index) * 18
                let rect = CGRect(x: size.width * 0.55 - inset, y: -size.height * 0.2 - inset,
                                  width: size.width * 0.75 + inset * 2, height: size.height * 1.5 + inset * 2)
                context.stroke(Path(ellipseIn: rect), with: .foreground, lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct FieldEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(FieldStyle.accent)
                .frame(width: 88, height: 88)
                .background(FieldStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 28))
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.semibold)).tracking(-0.5)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct FieldThumbnail: View {
    var data: Data?
    var icon = "cube.transparent"

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                FieldStyle.accent.opacity(0.08)
                if let data, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    ContourArtwork().foregroundStyle(FieldStyle.accent.opacity(0.10))
                    Image(systemName: icon).font(.system(size: min(geometry.size.width * 0.32, 44), weight: .light))
                        .foregroundStyle(FieldStyle.accent)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct FieldBadge: View {
    let title: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon) }
            Text(title)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .foregroundStyle(FieldStyle.accent)
        .background(FieldStyle.accent.opacity(0.08), in: Capsule())
    }
}

struct FieldIcon: View {
    let symbol: String
    var selected = false
    var body: some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium))
            .frame(minWidth: 46, minHeight: 46)
            .foregroundStyle(selected ? FieldStyle.ink : .white)
            .background(selected ? FieldStyle.mint : FieldStyle.panel,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}
