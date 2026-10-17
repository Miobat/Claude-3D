import SwiftUI

/// TinyCorp's graphite / titanium / ice visual language.
/// Brand cyan is intentionally separate from green photo-quality evidence.
enum FieldStyle {
    static let accent = Color("AccentColor")
    static let cyan = Color(red: 0.471, green: 0.871, blue: 0.929)
    static let mint = Color(red: 0.43, green: 0.91, blue: 0.78)
    static let ink = Color(red: 0.047, green: 0.063, blue: 0.090)
    static let viewport = Color(red: 0.059, green: 0.078, blue: 0.110)
    static let panel = Color(red: 0.090, green: 0.118, blue: 0.161)
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.047, green: 0.063, blue: 0.090, alpha: 1)
            : UIColor(red: 0.945, green: 0.957, blue: 0.973, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.078, green: 0.102, blue: 0.141, alpha: 1)
            : .white
    })
    static let line = Color.primary.opacity(0.10)
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
        background(LinearGradient(colors: [FieldStyle.panel, FieldStyle.viewport], startPoint: .topLeading, endPoint: .bottomTrailing),
                   in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
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
            .background(prominent ? FieldStyle.cyan : FieldStyle.surface,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(FieldStyle.line, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// The same product mark used on the home screen; never substitutes for scan data.
struct TinyScannerMark: View {
    var size: CGFloat = 44
    var body: some View {
        Image("TinyScannerMark").resizable().scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct FieldHero: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let eyebrow: String
    let title: String
    let subtitle: String
    var icon = "viewfinder"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !typeSize.isAccessibilitySize {
                if eyebrow == AppConstants.brandName {
                    HStack(spacing: 12) {
                        TinyScannerMark()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppConstants.appName).font(.headline).tracking(-0.3)
                            Text("by \(AppConstants.companyName)").font(.caption).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    Label(eyebrow.uppercased(), systemImage: icon)
                        .font(.caption.weight(.semibold)).tracking(1.4)
                        .foregroundStyle(FieldStyle.cyan)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(typeSize.isAccessibilitySize ? .headline : .title2.weight(.semibold)).tracking(-0.5)
                    .fixedSize(horizontal: false, vertical: true)
                if !typeSize.isAccessibilitySize {
                    Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(alignment: .trailing) {
            ZStack {
                LinearGradient(colors: [FieldStyle.panel, FieldStyle.ink], startPoint: .topLeading, endPoint: .bottomTrailing)
                SpatialArtwork().foregroundStyle(FieldStyle.cyan.opacity(0.07))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Quiet architectural planes echo the icon. Decorative, not captured geometry.
struct SpatialArtwork: View {
    var body: some View {
        Canvas { context, size in
            for index in 0..<5 {
                let offset = CGFloat(index) * size.width * 0.12
                var path = Path()
                path.move(to: CGPoint(x: size.width * 0.55 + offset, y: -20))
                path.addLine(to: CGPoint(x: size.width * 0.78 + offset, y: size.height * 0.42))
                path.addLine(to: CGPoint(x: size.width * 0.45 + offset, y: size.height + 20))
                context.stroke(path, with: .foreground, lineWidth: 1)
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
                    SpatialArtwork().foregroundStyle(FieldStyle.accent.opacity(0.10))
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
            .background(selected ? FieldStyle.cyan : FieldStyle.panel,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}
