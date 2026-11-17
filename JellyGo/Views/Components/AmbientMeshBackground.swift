import SwiftUI
import Combine
import UIKit

/// Colours pulled from an artwork, as plain RGB so they can be compared and interpolated.
struct AmbientPalette: Equatable, Sendable {
    /// top-left, top-right, bottom-left, bottom-right of the artwork
    var colors: [SIMD3<Double>]

    static let neutral = AmbientPalette(colors: Array(repeating: SIMD3(0.10, 0.10, 0.12), count: 4))

    /// App colours (bordo on black) for pages that are not about a specific title.
    static let brand = AmbientPalette(colors: [
        SIMD3(0.44, 0.05, 0.11), SIMD3(0.24, 0.02, 0.07),
        SIMD3(0.30, 0.03, 0.08), SIMD3(0.52, 0.08, 0.13),
    ])

    func mixed(with other: AmbientPalette, _ t: Double) -> AmbientPalette {
        AmbientPalette(colors: zip(colors, other.colors).map { $0 + ($1 - $0) * t })
    }
}

extension UIImage {
    /// Averages the four quadrants of the image and tunes them for use behind white text:
    /// saturation is lifted so the colour reads on black, brightness is clamped so it never
    /// washes out the content on top. Cheap (8×8 downsample); call off the main thread.
    nonisolated func ambientPalette() -> AmbientPalette? {
        guard let cg = cgImage else { return nil }
        let side = 8
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        func quadrant(_ xs: Range<Int>, _ ys: Range<Int>) -> SIMD3<Double> {
            var sum = SIMD3<Double>(0, 0, 0)
            var n = 0.0
            for y in ys { for x in xs {
                let i = (y * side + x) * 4
                sum += SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255
                n += 1
            } }
            return Self.tuned(sum / max(n, 1))
        }
        let h = side / 2
        // Bitmap rows run top → bottom in this context.
        return AmbientPalette(colors: [
            quadrant(0..<h, 0..<h), quadrant(h..<side, 0..<h),
            quadrant(0..<h, h..<side), quadrant(h..<side, h..<side),
        ])
    }

    nonisolated private static func tuned(_ c: SIMD3<Double>) -> SIMD3<Double> {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
        UIColor(red: c.x, green: c.y, blue: c.z, alpha: 1).getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
        // Leave near-greys grey (boosting them invents a random hue).
        // Keep the artwork's hue but hold it back: muted enough that the bordo controls on
        // top never fight a strongly coloured poster. Near-greys stay grey.
        if sat > 0.08 { sat = min(0.48, sat * 0.95) }
        bri = min(max(bri, 0.20), 0.42)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        UIColor(hue: hue, saturation: sat, brightness: bri, alpha: 1).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Double(r), Double(g), Double(b))
    }
}

/// Black canvas with a slowly drifting mesh gradient tinted by the featured artwork.
/// Colour sits at the top and melts into pure black toward the bottom.
struct AmbientMeshBackground: View {
    let palette: AmbientPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    // Palette cross-fade state (interpolated by hand so it composes with the drift).
    @State private var from = AmbientPalette.neutral
    @State private var to = AmbientPalette.neutral
    @State private var changedAt = Date.distantPast

    private let fadeDuration = 1.2

    @ObservedObject private var motion = BackgroundMotion.shared

    private var isStill: Bool {
        reduceMotion || scenePhase != .active || ProcessInfo.processInfo.isLowPowerModeEnabled
            || motion.isCovered
    }

    var body: some View {
        // 20 fps is plenty for a slow drift and keeps the GPU mostly idle.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: isStill)) { context in
            mesh(at: context.date)
        }
        .background(JGColor.canvas)
        .onAppear { from = palette; to = palette }
        .onChange(of: palette) { _, new in
            from = current(at: Date())
            to = new
            changedAt = Date()
        }
    }

    private func current(at date: Date) -> AmbientPalette {
        let t = min(max(date.timeIntervalSince(changedAt) / fadeDuration, 0), 1)
        let eased = t * t * (3 - 2 * t)
        return from.mixed(with: to, eased)
    }

    private func mesh(at date: Date) -> some View {
        let p = current(at: date).colors
        let t = isStill ? 0 : date.timeIntervalSinceReferenceDate
        func wave(_ period: Double, _ phase: Double = 0) -> Float { Float(sin(t / period * 2 * .pi + phase)) }
        func color(_ c: SIMD3<Double>, _ k: Double = 1) -> Color {
            Color(red: c.x * k, green: c.y * k, blue: c.z * k)
        }
        let topMid = (p[0] + p[1]) / 2
        let lowMid = (p[2] + p[3]) / 2

        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5 + 0.16 * wave(11), 0], [1, 0],
                [0, 0.46 + 0.07 * wave(9, 1.3)],
                [0.5 + 0.14 * wave(13, 0.6), 0.42 + 0.09 * wave(7, 2.1)],
                [1, 0.50 + 0.08 * wave(10, 3.0)],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                color(p[0]), color(topMid, 0.9), color(p[1]),
                color(p[2], 0.55), color(lowMid, 0.7), color(p[3], 0.55),
                JGColor.canvas, JGColor.canvas, JGColor.canvas,
            ],
            smoothsColors: true
        )
    }
}

/// One palette for the whole app. A page that shows a specific item (detail) pushes its
/// artwork colours while it is on screen; so does the hero banner of the visible tab.
final class AmbientStore: ObservableObject {
    static let shared = AmbientStore()

    @Published private(set) var palette = AmbientPalette.neutral
    /// Number of detail pages currently open. Hero banners hold their slide while it is > 0.
    private(set) var openDetailCount = 0
    func detailDidAppear() { openDetailCount += 1 }
    func detailDidDisappear() { openDetailCount = max(0, openDetailCount - 1) }
    private var overrides: [(owner: UUID, palette: AmbientPalette)] = []

    func push(_ palette: AmbientPalette, owner: UUID) {
        overrides.removeAll { $0.owner == owner }
        overrides.append((owner, palette))
        refresh()
    }

    func pop(owner: UUID) {
        overrides.removeAll { $0.owner == owner }
        refresh()
    }

    private func refresh() {
        // With no page claiming the background (Settings, lists …) keep the last colours
        // instead of snapping back to neutral.
        guard let new = overrides.last?.palette else { return }
        if new != palette { palette = new }
    }
}

/// The shared ambient background. Pages install it with
/// `.containerBackground(for: .navigation) { AmbientBackdrop() }` so it belongs to the
/// navigation container rather than to the sliding page.
struct AmbientBackdrop: View {
    @ObservedObject private var store = AmbientStore.shared
    /// When set, the page ignores the current artwork colours and uses this palette.
    var fixed: AmbientPalette? = nil

    var body: some View {
        AmbientMeshBackground(palette: fixed ?? store.palette)
            .ignoresSafeArea()
    }
}

extension View {
    /// Puts the shared ambient background behind a page of a NavigationStack.
    func ambientPage() -> some View {
        containerBackground(for: .navigation) { AmbientBackdrop() }
    }

    /// Drifting gradient in the app's own colours, for pages that are not about a title
    /// (Settings, Live TV, Search, Downloads).
    func brandPage() -> some View {
        containerBackground(for: .navigation) { BrandGlowBackground() }
    }

    /// For `List`/`Form` settings pages: brand background, opaque list background removed.
    /// Settings sub-pages: bordo switches/checkmarks (iOS switches ignore the accent colour
    /// otherwise and turn green) and the same bordo icon badges as the main Settings page.
    func ambientList() -> some View {
        scrollContentBackground(.hidden)
            .tint(JGColor.brand)
            .labelStyle(SettingsBadgeLabelStyle())
            .brandPage()
    }
}

// MARK: - Zoom navigation (detail grows out of the tapped card)

private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

private struct ZoomScope: ViewModifier {
    @Namespace private var namespace
    func body(content: Content) -> some View {
        content.environment(\.zoomNamespace, namespace)
    }
}

private struct ZoomSource: ViewModifier {
    let id: String
    @Environment(\.zoomNamespace) private var namespace
    func body(content: Content) -> some View {
        if let namespace { content.matchedTransitionSource(id: id, in: namespace) } else { content }
    }
}

private struct ZoomDestination: ViewModifier {
    let id: String?
    @Environment(\.zoomNamespace) private var namespace
    func body(content: Content) -> some View {
        if let namespace, let id { content.navigationTransition(.zoom(sourceID: id, in: namespace)) } else { content }
    }
}

extension View {
    /// Provides the namespace that links cards to the detail pages they open.
    func zoomScope() -> some View { modifier(ZoomScope()) }
    /// Marks a card as the origin of the zoom into the item with this id.
    func zoomSource(_ id: String) -> some View { modifier(ZoomSource(id: id)) }
    /// Makes this page open by growing out of the matching `zoomSource`.
    func zoomDestination(_ id: String?) -> some View { modifier(ZoomDestination(id: id)) }
}

/// The ambient gradient as part of a page's scroll content: a fixed-height block at the top
/// that scrolls away with the artwork and ends in black, instead of a layer that stays put.
struct AmbientScrollingBackdrop: View {
    @ObservedObject private var store = AmbientStore.shared
    var height: CGFloat = 1200

    var body: some View {
        AmbientMeshBackground(palette: store.palette)
            .frame(height: height)
            .allowsHitTesting(false)
    }
}

extension View {
    /// Translucent card that sits on the ambient background.
    /// `bordered: false` matches the grouped lists of the settings sub-pages (no hairline).
    func glassCard(cornerRadius: CGFloat = 16, highlighted: Bool = false, bordered: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.ultraThinMaterial, in: shape)
            .background(highlighted ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.04), in: shape)
            .overlay(shape.strokeBorder(highlighted ? Color.accentColor.opacity(0.9)
                                        : Color.white.opacity(bordered ? 0.14 : 0),
                                        lineWidth: highlighted ? 1.5 : 0.5))
            .contentShape(shape)
    }
}

/// Lets a tapped view name the zoom source for the detail page it is about to open.
/// Needed when the same item is on screen twice (hero banner + a row card): matched ids
/// must be unique, so the banner registers as "hero-<id>" and announces it here.
enum ZoomContext {
    nonisolated(unsafe) private static var pending: (itemId: String, sourceId: String, at: CFAbsoluteTime)?

    static func announce(itemId: String, sourceId: String) {
        pending = (itemId, sourceId, CFAbsoluteTimeGetCurrent())
    }

    /// The announced source for this item, or nil when nothing announced one (the page then
    /// opens with the normal push).
    static func sourceId(for itemId: String) -> String? {
        defer { pending = nil }
        if let p = pending, p.itemId == itemId, CFAbsoluteTimeGetCurrent() - p.at < 1 { return p.sourceId }
        return nil
    }
}

/// Background for pages that are not about a title: near-black canvas with a few soft
/// bordo glows drifting near the top corners. Most of the page stays black so the cards
/// carry the screen; the colour is an accent, not a wash.
struct BrandGlowBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject private var motion = BackgroundMotion.shared

    private var isStill: Bool {
        reduceMotion || scenePhase != .active || ProcessInfo.processInfo.isLowPowerModeEnabled
            || motion.isCovered
    }

    /// One soft, slow-drifting patch of colour (unit coordinates of the page).
    private struct Patch {
        let color: Color
        let center: CGPoint, radius: CGSize
        let period: Double, phase: Double
    }

    // "Muted aurora": three bordo tones on the canvas black — low saturation, wide and blurry.
    private let patches: [Patch] = [
        Patch(color: Color(red: 0.300, green: 0.050, blue: 0.105),
              center: CGPoint(x: 0.25, y: 0.15), radius: CGSize(width: 0.62, height: 0.36), period: 19, phase: 0),
        Patch(color: Color(red: 0.180, green: 0.032, blue: 0.068),
              center: CGPoint(x: 0.85, y: 0.44), radius: CGSize(width: 0.56, height: 0.31), period: 23, phase: 2.4),
        Patch(color: Color(red: 0.235, green: 0.045, blue: 0.090),
              center: CGPoint(x: 0.38, y: 0.89), radius: CGSize(width: 0.66, height: 0.36), period: 27, phase: 4.1),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: isStill)) { context in
            let t = isStill ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for p in patches {
                    let wave = sin(t / p.period * 2 * .pi + p.phase)
                    let cx = (p.center.x + 0.07 * wave) * size.width
                    let cy = (p.center.y + 0.05 * wave) * size.height
                    let rx = p.radius.width * size.width
                    let ry = p.radius.height * size.height
                    // Draw a unit circle gradient stretched to an ellipse.
                    var c = ctx
                    c.translateBy(x: cx, y: cy)
                    c.scaleBy(x: rx, y: ry)
                    c.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                           with: .radialGradient(
                            Gradient(stops: [
                                .init(color: p.color.opacity(0.85), location: 0),
                                .init(color: p.color.opacity(0.55), location: 0.45),
                                .init(color: p.color.opacity(0), location: 1),
                            ]),
                            center: .zero, startRadius: 0, endRadius: 1))
                }
            }
        }
        .background(JGColor.canvas)
        .ignoresSafeArea()
    }
}

/// Label with its icon in a small bordo badge, as on the main Settings page.
struct SettingsBadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(JGColor.brandGradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            configuration.title
        }
    }
}

/// Stops the animated page backgrounds while something covers them completely (the
/// full-screen player). They kept drifting at 20 fps behind the video, unseen.
@MainActor
final class BackgroundMotion: ObservableObject {
    static let shared = BackgroundMotion()
    @Published private(set) var isCovered = false
    private var coverCount = 0

    func cover() { coverCount += 1; update() }
    func uncover() { coverCount = max(0, coverCount - 1); update() }
    private func update() {
        let covered = coverCount > 0
        if covered != isCovered { isCovered = covered }
    }
}
