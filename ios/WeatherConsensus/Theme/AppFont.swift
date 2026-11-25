import CoreText
import SwiftUI
import os

/// Inter, bundled in `Fonts/` with its SIL Open Font License (`Fonts/Inter-OFL.txt`).
/// Source: the official Inter 4.1 release, https://github.com/rsms/inter/releases/tag/v4.1 (static TTFs).
///
/// Fonts are registered in code for this process only, so no Info.plist key is needed and
/// previews (which skip the app's `init`) get them too.
nonisolated enum AppFont {
    enum Weight: String, CaseIterable, Sendable {
        case regular = "Inter-Regular"
        case medium = "Inter-Medium"
        case semibold = "Inter-SemiBold"
        case bold = "Inter-Bold"
        case extraBold = "Inter-ExtraBold"
    }

    private static let log = Logger(subsystem: "WeatherConsensus", category: "fonts")

    /// Registers the bundled Inter files once. Safe to call from anywhere, any number of times.
    static let registered: Bool = {
        var ok = true
        for weight in Weight.allCases {
            guard let url = Bundle.main.url(forResource: weight.rawValue, withExtension: "ttf") else {
                log.error("Missing font file \(weight.rawValue, privacy: .public).ttf")
                ok = false
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered is fine (previews can load the module more than once).
                let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? 0
                if code != CTFontManagerError.alreadyRegistered.rawValue {
                    log.error("Could not register \(weight.rawValue, privacy: .public): \(code)")
                    ok = false
                }
            }
        }
        return ok
    }()
}

extension Font {
    /// Inter at a design size that scales with Dynamic Type like `style`.
    static func inter(_ size: CGFloat, _ weight: AppFont.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        _ = AppFont.registered
        return .custom(weight.rawValue, size: size, relativeTo: style)
    }
}
