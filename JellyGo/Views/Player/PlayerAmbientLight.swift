import SwiftUI
import CoreVideo
import VideoToolbox
import QuartzCore
import Combine

// MARK: - Setting

enum AmbientLightMode: String, CaseIterable, Identifiable {
    case off, subtle, strong
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "Off", bundle: AppState.currentBundle)
        case .subtle: String(localized: "Subtle", bundle: AppState.currentBundle)
        case .strong: String(localized: "Strong", bundle: AppState.currentBundle)
        }
    }

    /// How much of the glow shows through over the black bars.
    var opacity: Double {
        switch self {
        case .off: 0
        case .subtle: 0.45
        case .strong: 0.75
        }
    }
}

// MARK: - Frame scaler

/// Shrinks a decoded frame (any size / YUV format) to a 160x90 BGRA buffer in hardware.
/// Used for KSMEPlayer; KSAVPlayer gets the same size straight from AVPlayerItemVideoOutput.
final class AmbientFrameScaler {
    private var session: VTPixelTransferSession?
    private var output: CVPixelBuffer?

    func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        if session == nil {
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        }
        if output == nil {
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
            CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, attrs, &output)
        }
        guard let session, let output,
              VTPixelTransferSessionTransferImage(session, from: source, to: output) == noErr
        else { return nil }
        return output
    }
}

// MARK: - Sampler

/// "Ambient mode": a few times a second the (already tiny, hardware-scaled) frame is averaged
/// into a 5x3 grid of colours. The backdrop draws them as a MeshGradient, which the GPU
/// renders perfectly smooth, and animates between grids, so colours flow instead of stepping.
/// Each new grid is also blended into the previous one (as in published recreations of
/// YouTube's effect), so cuts and flashes never strobe the bars.
@MainActor
final class AmbientSampler: ObservableObject {
    static let columns = 5
    static let rows = 3

    /// The backdrop glides from `from` to `to` over `transition` seconds starting at `start`.
    /// It redraws itself at 24 fps while moving (a SwiftUI animation would redraw at the
    /// display's 120 Hz and keep ProMotion from dropping to the video's frame rate).
    @Published private(set) var to: [SIMD3<Float>] = []
    @Published private(set) var isMoving = false
    private(set) var from: [SIMD3<Float>] = []
    private(set) var start: TimeInterval = 0
    let transition: TimeInterval = 0.6
    private var settleWork: DispatchWorkItem?

    private var timer: Timer?
    private var source: (() -> CVPixelBuffer?)?
    private var average: [SIMD3<Float>] = []

    /// Samples per second; the animation in the backdrop fills the time in between.
    private let rate: Double = 4

    func start(source: @escaping () -> CVPixelBuffer?) {
        self.source = source
        guard timer == nil else { return }
        average = []
        let t = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        source = nil
        settleWork?.cancel()
        isMoving = false
    }

    /// Grid colour at time `now`, eased between the previous and the latest target.
    func colors(at now: TimeInterval) -> [Color] {
        let t = Float(min(1, max(0, (now - start) / transition)))
        let e = t * t * (3 - 2 * t)                       // smoothstep
        return to.indices.map { i in
            let a = i < from.count ? from[i] : to[i]
            let c = a + (to[i] - a) * e
            return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
        }
    }

    private func tick() {
        guard let buffer = source?(), let grid = Self.grid(of: buffer) else { return }
        if average.count != grid.count {
            average = grid
        } else {
            // Reduce Motion: drift towards new colours more slowly.
            let w: Float = UIAccessibility.isReduceMotionEnabled ? 0.1 : 0.3
            for i in average.indices { average[i] = average[i] * (1 - w) + grid[i] * w }
        }
        let next = average.map { c -> SIMD3<Float> in
            // A touch more saturation, like YouTube's glow.
            let luma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            let s = (c - SIMD3(repeating: luma)) * 1.25 + SIMD3(repeating: luma)
            return s.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
        }
        // Start the next glide from wherever the current one is now: no jumps.
        let now = CACurrentMediaTime()
        let t = Float(min(1, max(0, (now - start) / transition)))
        let e = t * t * (3 - 2 * t)
        from = to.isEmpty ? next : to.indices.map { i in
            let a = i < from.count ? from[i] : to[i]
            return a + (to[i] - a) * e
        }
        start = now
        to = next
        if !isMoving { isMoving = true }
        // Stop redrawing once the colours have settled (paused video, static scene).
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.isMoving = false }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + transition + 0.05, execute: work)
    }

    /// Average colour of each grid cell of a small BGRA frame (~14k pixels: microseconds).
    private static func grid(of buffer: CVPixelBuffer) -> [SIMD3<Float>]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard w >= columns, h >= rows else { return nil }
        let px = base.assumingMemoryBound(to: UInt8.self)
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(columns * rows)
        // Rows top to bottom (pixel row 0 is the top of the picture).
        for gy in 0..<rows {
            let y0 = gy * h / rows, y1 = (gy + 1) * h / rows
            for gx in 0..<columns {
                let x0 = gx * w / columns, x1 = (gx + 1) * w / columns
                var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0
                for y in y0..<y1 {
                    let row = px + y * rowBytes
                    for x in x0..<x1 {
                        let p = row + x * 4
                        b += UInt32(p[0]); g += UInt32(p[1]); r += UInt32(p[2])
                    }
                }
                let n = Float((y1 - y0) * (x1 - x0)) * 255
                out.append(SIMD3(Float(r) / n, Float(g) / n, Float(b) / n))
            }
        }
        return out
    }
}

// MARK: - Backdrop

/// Full-screen mesh gradient of the picture's colours, drawn under the video. The picture's
/// left and right columns land in the black bars beside it.
struct PlayerAmbientBackdrop: View {
    @ObservedObject var sampler: AmbientSampler
    let opacity: Double

    private static let points: [SIMD2<Float>] = {
        var p: [SIMD2<Float>] = []
        for y in 0..<AmbientSampler.rows {
            for x in 0..<AmbientSampler.columns {
                p.append(SIMD2(Float(x) / Float(AmbientSampler.columns - 1),
                               Float(y) / Float(AmbientSampler.rows - 1)))
            }
        }
        return p
    }()

    var body: some View {
        ZStack {
            if sampler.to.count == Self.points.count {
                // 24 fps (the video's own pace) while colours move, nothing when settled.
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !sampler.isMoving)) { _ in
                    MeshGradient(width: AmbientSampler.columns, height: AmbientSampler.rows,
                                 points: Self.points,
                                 colors: sampler.colors(at: CACurrentMediaTime()),
                                 smoothsColors: true)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: sampler.to.isEmpty)
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}
