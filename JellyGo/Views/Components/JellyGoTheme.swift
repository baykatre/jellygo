import SwiftUI

/// The app's single colour palette. Every screen takes its colours from here so the bordo,
/// the status colours and the background black stay the same tone everywhere.
nonisolated enum JGColor {
    // MARK: Brand (bordo)
    /// Accent: buttons, selected states, icon badges, live dot, favourite heart.
    static let brand = Color(red: 0.769, green: 0.165, blue: 0.251)      // #C42A40
    /// Darker end of brand gradients.
    static let brandDeep = Color(red: 0.549, green: 0.078, blue: 0.157)  // #8C1428
    /// Very dark bordo used as a tint inside backgrounds.
    static let brandShade = Color(red: 0.227, green: 0.039, blue: 0.078) // #3A0A14

    static let brandGradient = LinearGradient(colors: [brand, brandDeep],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Status (muted; small marks only)
    static let success = Color(red: 0.373, green: 0.749, blue: 0.541)    // watched, direct play
    static let warning = Color(red: 0.851, green: 0.627, blue: 0.314)    // transcoding, buffering
    static let danger = Color(red: 0.898, green: 0.282, blue: 0.302)     // delete, errors

    // MARK: Pro
    static let goldTop = Color(red: 0.949, green: 0.769, blue: 0.420)
    static let goldBottom = Color(red: 0.851, green: 0.557, blue: 0.227)
    static let goldGradient = LinearGradient(colors: [goldTop, goldBottom],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Neutrals
    /// The one background black for every page, sheet and overlay.
    static let canvas = Color(red: 0.031, green: 0.027, blue: 0.039)     // #08070A
    /// Bottom sheets: one step above the page black, so a sheet reads as a raised card.
    static let sheet = Color(red: 0.090, green: 0.082, blue: 0.106)      // #17151B
    /// Image placeholders and empty surfaces.
    static let placeholder = Color(red: 0.102, green: 0.094, blue: 0.114) // #1A181D
}
