import AppKit
import MurmurCore
import SwiftUI

/// Colors and type from call-memory's DESIGN.md. The web page uses oklch; these are sRGB approximations that
/// follow the system appearance. Warm neutrals tinted toward the ink-teal accent (hue 195); never pure black or white.
enum LiveTheme {
    private static func color(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }

    static let background = color(light: (0.965, 0.957, 0.937), dark: (0.105, 0.133, 0.137))
    static let surface = color(light: (0.985, 0.980, 0.970), dark: (0.130, 0.160, 0.165))
    static let raised = color(light: (0.996, 0.994, 0.990), dark: (0.160, 0.190, 0.200))
    static let line = color(light: (0.870, 0.860, 0.830), dark: (0.200, 0.230, 0.240))
    static let accent = color(light: (0.106, 0.420, 0.416), dark: (0.420, 0.790, 0.770))
    static let accentSoft = color(light: (0.860, 0.930, 0.925), dark: (0.140, 0.230, 0.235))
    static let accentInk = color(light: (0.975, 0.990, 0.990), dark: (0.090, 0.140, 0.145))
    static let ok = color(light: (0.180, 0.490, 0.310), dark: (0.420, 0.810, 0.580))
    static let warn = color(light: (0.540, 0.350, 0.000), dark: (0.880, 0.690, 0.290))
    static let warnSoft = color(light: (0.985, 0.930, 0.800), dark: (0.250, 0.200, 0.080))
    static let fail = color(light: (0.700, 0.150, 0.120), dark: (1.000, 0.540, 0.500))

    /// Transcript and notes: a text serif (New York) at 17 pt; UI chrome stays in the system face.
    static func reading(_ size: CGFloat = 17, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func color(for state: ReadinessState) -> Color {
        switch state {
        case .ok: ok
        case .warn: warn
        case .fail: fail
        }
    }
}
