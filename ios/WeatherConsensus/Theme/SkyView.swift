import SwiftUI

/// The living sky behind the Weather tab: gradient and glow for the time of day, and, once the
/// forecast file has a condition, the weather drawn on top (sun or moon, stars, clouds, rain, snow, fog).
/// Shapes follow the canvas `Sky` component, laid out on its 390 pt wide frame and scaled to fit.
struct SkyView: View {
    let style: SkyStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, 1)
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: Color(style.top), location: 0),
                        .init(color: Color(style.middle), location: min(SkyStyle.middleStop / height, 0.99)),
                        .init(color: Color(style.base), location: min(SkyStyle.baseStop / height, 1)),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                RadialGradient(
                    colors: [Color(style.glow).opacity(style.glowOpacity), Color(style.glow).opacity(0)],
                    center: UnitPoint(x: style.glowX, y: style.glowY / height),
                    startRadius: 0, endRadius: 210
                )
                if let weather = style.weather {
                    if reduceMotion {
                        SkyLayer(time: style.time, weather: weather, phase: 0)
                    } else {
                        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                            SkyLayer(time: style.time, weather: weather,
                                     phase: context.date.timeIntervalSinceReferenceDate)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Weather shapes for one moment. `phase` is seconds; rain, snow, clouds and fog drift with it.
private struct SkyLayer: View {
    let time: SkyTime
    let weather: SkyWeather
    let phase: Double

    private struct Opacities {
        var sun = 0.0, moon = 0.0, stars = 0.0, fewStars = 0.0, clouds = 0.0, bigClouds = 0.0
        var rain = 0.0, snow = 0.0, fog = 0.0
    }

    private var night: Bool { time == .night }

    /// Canvas `Sky` component rules.
    private var opacities: Opacities {
        var o = Opacities()
        switch weather {
        case .clear:
            if night { o.moon = 1; o.stars = 1 } else { o.sun = 1; o.clouds = 0.5 }
        case .cloudy:
            o.clouds = night ? 0.22 : 0.7; o.bigClouds = night ? 0.18 : 0.6
            if night { o.fewStars = 0.8 }
        case .rain:
            o.clouds = night ? 0.16 : 0.45; o.bigClouds = night ? 0.12 : 0.35; o.rain = night ? 0.45 : 0.6
        case .snow:
            o.clouds = night ? 0.16 : 0.55; o.bigClouds = night ? 0.12 : 0.4; o.snow = night ? 0.9 : 1
        case .storm:
            o.clouds = night ? 0.14 : 0.3; o.bigClouds = night ? 0.14 : 0.32; o.rain = night ? 0.4 : 0.55
        case .fog:
            o.fog = 1
            if night { o.moon = 0.35 } else { o.sun = 0.5 }
        }
        return o
    }

    private var sunPosition: CGPoint {
        switch time {
        case .dawn: CGPoint(x: 206, y: 44)
        case .dusk: CGPoint(x: 246, y: 48)
        case .day, .night: CGPoint(x: 262, y: 38)
        }
    }

    private var sunFill: RGB {
        switch time {
        case .dawn: RGB(0xFFD3A0)
        case .dusk: RGB(0xFFB487)
        case .day, .night: RGB(0xFFE27A)
        }
    }

    private var cloudFill: Color {
        night ? Color(RGB(0xB9C6EE)) : (weather == .storm ? Color(RGB(0xF3EEFF)) : .white)
    }

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 390
            context.scaleBy(x: scale, y: scale)
            let o = opacities

            if o.sun > 0 {
                var c = context
                c.opacity = o.sun
                let p = sunPosition
                c.fill(circle(p, 48), with: .color(Color(RGB(0xFFF6D6)).opacity(0.3)))
                c.fill(circle(p, 32), with: .color(Color(RGB(0xFFF3C8)).opacity(0.45)))
                c.fill(circle(p, 20), with: .color(Color(sunFill)))
            }
            if o.moon > 0 {
                var c = context
                c.opacity = o.moon
                c.fill(circle(CGPoint(x: 256, y: 44), 42), with: .color(Color(RGB(0xC9D6FF)).opacity(0.12)))
                var crescent = Path()
                crescent.addEllipse(in: CGRect(x: 236, y: 26, width: 30, height: 30))
                let bite = Path(ellipseIn: CGRect(x: 246, y: 18, width: 28, height: 28))
                c.fill(crescent.subtracting(bite), with: .color(Color(RGB(0xFFF0C2))))
            }
            for (opacity, stars) in [(o.stars, Self.stars), (o.fewStars, Self.fewStars)] where opacity > 0 {
                for (index, star) in stars.enumerated() {
                    let twinkle = index % 3 == 0 ? 0.65 + 0.35 * sin(phase * 2 + Double(index)) : 1
                    context.fill(circle(CGPoint(x: star.x, y: star.y), star.z),
                                 with: .color(.white.opacity(opacity * twinkle)))
                }
            }
            if o.clouds > 0 {
                let dx = 7 * (1 - cos(phase * 2 * .pi / 40))
                for cloud in Self.clouds {
                    context.fill(cloudPath(cloud).offsetBy(dx: dx, dy: 0), with: .color(cloudFill.opacity(o.clouds)))
                }
            }
            if o.bigClouds > 0 {
                let dx = -6 * (1 - cos(phase * 2 * .pi / 52))
                for cloud in Self.bigClouds {
                    context.fill(cloudPath(cloud).offsetBy(dx: dx, dy: 0), with: .color(cloudFill.opacity(o.bigClouds)))
                }
            }
            if o.rain > 0 {
                let colour = night ? Color(RGB(0x9FE3EA)) : .white
                for (period, shift) in [(1.1, CGSize.zero), (1.4, CGSize(width: 16, height: 26))] {
                    let t = phase.truncatingRemainder(dividingBy: period) / period
                    let offset = CGSize(width: 5 - 10 * t + shift.width, height: -34 + 68 * t + shift.height)
                    var streaks = Path()
                    for drop in Self.drops {
                        streaks.move(to: CGPoint(x: drop.x + offset.width, y: drop.y + offset.height))
                        streaks.addLine(to: CGPoint(x: drop.x - 3 + offset.width, y: drop.y + 10 + offset.height))
                    }
                    context.stroke(streaks, with: .color(colour.opacity(o.rain)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            if o.snow > 0 {
                for (period, drift, shift) in [(7.0, 9.0, CGSize.zero), (9.0, -7.0, CGSize(width: 20, height: 34))] {
                    let t = phase.truncatingRemainder(dividingBy: period) / period
                    for flake in Self.flakes {
                        let p = CGPoint(x: flake.x + drift * t + shift.width, y: flake.y - 30 + 60 * t + shift.height)
                        context.fill(circle(p, flake.z), with: .color(.white.opacity(o.snow)))
                    }
                }
            }
            if o.fog > 0 {
                let dx = 11 * (1 - cos(phase * 2 * .pi / 30))
                let fill = night ? Color(RGB(0xCDD4F0)).opacity(0.16) : Color.white.opacity(0.5)
                for band in Self.fogBands {
                    let rect = band.offsetBy(dx: dx, dy: 0)
                    context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(fill.opacity(o.fog)))
                }
            }
        }
    }

    private func circle(_ centre: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }

    /// A cloud as overlapping round puffs on a flat base: (left, base y, width).
    private func cloudPath(_ c: SIMD3<Double>) -> Path {
        let (x, y, w) = (c.x, c.y, c.z)
        var path = Path()
        path.addRoundedRect(in: CGRect(x: x, y: y - 22, width: w, height: 22), cornerSize: CGSize(width: 11, height: 11))
        path.addEllipse(in: CGRect(x: x + w * 0.12, y: y - 44, width: w * 0.34, height: 40))
        path.addEllipse(in: CGRect(x: x + w * 0.34, y: y - 56, width: w * 0.40, height: 50))
        path.addEllipse(in: CGRect(x: x + w * 0.62, y: y - 40, width: w * 0.30, height: 36))
        return path
    }

    // Positions from the canvas, on a 390 pt frame. Stars: (x, y, radius).
    private static let stars: [SIMD3<Double>] = [
        [22, 12, 1.3], [58, 30, 1], [96, 9, 1.5], [134, 52, 1], [168, 18, 1.3], [198, 62, 0.9], [214, 8, 1.1],
        [300, 12, 1.3], [322, 66, 1], [352, 9, 1.2], [381, 32, 1.4], [150, 70, 1], [8, 118, 1.1], [383, 150, 1],
        [7, 232, 1], [384, 300, 1.2], [9, 380, 0.9], [381, 440, 1],
    ]
    private static let fewStars: [SIMD3<Double>] = [[58, 30, 1], [168, 18, 1.3], [322, 66, 1], [381, 32, 1.3]]
    /// Clouds: (left, base y, width).
    private static let clouds: [SIMD3<Double>] = [[-30, 96, 180], [236, 84, 174]]
    private static let bigClouds: [SIMD3<Double>] = [[110, 66, 150], [-40, 48, 152], [290, 40, 130]]
    private static let drops: [CGPoint] = [
        (30, 10), (80, 40), (130, 4), (176, 30), (224, 12), (270, 44), (318, 20), (362, 50), (8, 90), (384, 100),
        (54, 70), (200, 70), (110, 60), (296, 74), (6, 170), (386, 200), (8, 260), (384, 300), (6, 360), (386, 420),
        (150, 24), (344, 8),
    ].map { CGPoint(x: $0.0, y: $0.1) }
    /// Snowflakes: (x, y, radius).
    private static let flakes: [SIMD3<Double>] = [
        [24, 14, 2.6], [70, 44, 2], [118, 8, 3], [160, 36, 2.2], [206, 60, 2.6], [240, 16, 2], [288, 40, 3],
        [332, 10, 2.2], [372, 54, 2.6], [98, 74, 2], [260, 78, 2.2], [150, 66, 1.8], [8, 110, 2.2], [384, 140, 2.6],
        [6, 210, 2], [384, 260, 2.4], [8, 330, 2.6], [382, 390, 2],
    ]
    private static let fogBands: [CGRect] = [
        CGRect(x: -60, y: 26, width: 300, height: 16), CGRect(x: 140, y: 54, width: 320, height: 14),
        CGRect(x: -40, y: 86, width: 280, height: 14), CGRect(x: 170, y: 118, width: 300, height: 12),
        CGRect(x: -50, y: 150, width: 260, height: 12),
    ]
}

#if DEBUG
#Preview("Every time of day x weather", arguments: SkyPreviewCase.all) { item in
    SkyView(style: SkyStyle(time: item.time, weather: item.weather))
        .overlay(alignment: .topLeading) {
            Text(verbatim: "\(item.time.rawValue), \(item.weather?.rawValue ?? "time only")")
                .font(.inter(15, .bold))
                .foregroundStyle(Color(SkyStyle(time: item.time, weather: item.weather).headerInk))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background {
                    let s = SkyStyle(time: item.time, weather: item.weather)
                    Capsule().fill(Color(s.headerBackdrop.color).opacity(s.headerBackdrop.opacity))
                }
                .padding(16)
        }
}

/// One preview cell: every time of day, with no weather (what ships now) and with each weather.
struct SkyPreviewCase: Hashable {
    let time: SkyTime
    let weather: SkyWeather?

    static let all: [SkyPreviewCase] = SkyTime.allCases.flatMap { time in
        [SkyPreviewCase(time: time, weather: nil)] + SkyWeather.allCases.map { SkyPreviewCase(time: time, weather: $0) }
    }
}
#endif
