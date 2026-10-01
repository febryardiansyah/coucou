import SwiftUI
import CoreGraphics

// MARK: - Main character choice

enum BotCharacter: String, CaseIterable, Identifiable {
    case mochi
    case cat

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mochi: return "Mochi"
        case .cat:   return "Bibol"
        }
    }
}

// MARK: - Palette

struct CatRGB {
    let r, g, b: CGFloat
    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { self.r = r; self.g = g; self.b = b }

    var color: Color { Color(red: r, green: g, blue: b) }
    func cg(alpha: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: alpha) }
    func mixed(with other: CGFloat, _ t: CGFloat) -> CatRGB {
        CatRGB(r + (other - r) * t, g + (other - g) * t, b + (other - b) * t)
    }
}

struct CatFur {
    var top: CatRGB
    var bottom: CatRGB
    var stripe: CatRGB
    var innerEar: CatRGB
    var cream = CatRGB(1.000, 0.945, 0.863)    // #FFF1DC
    var nose  = CatRGB(0.910, 0.475, 0.541)    // #E8798A
    var mouth = CatRGB(0.353, 0.165, 0.098)    // #5A2A19

    static let orange = CatFur(
        top:      CatRGB(1.000, 0.702, 0.318),   // #FFB351
        bottom:   CatRGB(0.937, 0.451, 0.106),   // #EF731B
        stripe:   CatRGB(0.741, 0.325, 0.055),   // #BD530E
        innerEar: CatRGB(1.000, 0.706, 0.659))   // #FFB4A8

    /// Fur in a single brand colour (integration pills), keeping the cream/nose/mouth details.
    static func tinted(_ base: CGColor) -> CatFur {
        guard let c = base.components, c.count >= 3 else { return .orange }
        let b = CatRGB(c[0], c[1], c[2])
        return CatFur(top: b.mixed(with: 1, 0.35), bottom: b, stripe: b.mixed(with: 0, 0.30), innerEar: b.mixed(with: 1, 0.55))
    }
}

// MARK: - Geometry (pure paths, in the bot's local space around its centre)

/// Where the face is looking: muzzle/nose/whiskers shift with the head turn.
struct CatFace {
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var squash: CGFloat = 1
}

enum CatShape {
    /// A short ear flick every few seconds (right ear only).
    static func flick(R: CGFloat, time: CGFloat) -> CGFloat {
        pow(max(0, sin(time * 0.8)), 24) * 0.07 * R
    }

    static func ear(side s: CGFloat, R: CGFloat, lean: CGFloat = 0, droop: CGFloat = 0,
                    tipShift: CGFloat = 0) -> (outer: Path, inner: Path) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: s * x * R, y: y * R) }
        let shift = lean + s * droop * R * 0.4

        var outer = Path()
        outer.move(to: pt(1.00, -0.42))
        outer.addLine(to: CGPoint(x: s * 0.84 * R + shift, y: (-1.22 + droop) * R + tipShift))
        outer.addLine(to: pt(0.26, -0.84))
        outer.closeSubpath()

        var inner = Path()
        inner.move(to: pt(0.84, -0.56))
        inner.addLine(to: CGPoint(x: s * 0.77 * R + shift, y: (-1.00 + droop) * R + tipShift))
        inner.addLine(to: pt(0.44, -0.80))
        inner.closeSubpath()
        return (outer, inner)
    }

    static func tail(R: CGFloat, wag: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0.82 * R, y: 0.50 * R))
        p.addQuadCurve(to: CGPoint(x: 1.34 * R + wag * 0.4, y: -0.06 * R + wag),
                       control: CGPoint(x: 1.46 * R, y: 0.62 * R))
        return p
    }

    static func foreheadStripes(R: CGFloat, ry: CGFloat, dx: CGFloat) -> [Path] {
        (-1...1).map { i in
            let fi = CGFloat(i)
            let x = fi * 0.26 * R + dx
            var p = Path()
            p.move(to: CGPoint(x: x, y: -ry * 1.02))
            p.addQuadCurve(to: CGPoint(x: x + fi * 0.03 * R, y: -ry * 0.46),
                           control: CGPoint(x: x + fi * 0.08 * R, y: -ry * 0.74))
            return p
        }
    }

    static func cheekStripes(rx: CGFloat, ry: CGFloat, dx: CGFloat) -> [Path] {
        var out: [Path] = []
        for s in [CGFloat(-1), 1] {
            for j in 0..<2 {
                let y = ry * (0.10 + CGFloat(j) * 0.20)
                var p = Path()
                p.move(to: CGPoint(x: s * rx * 1.02 + dx, y: y))
                p.addLine(to: CGPoint(x: s * rx * 0.80 + dx, y: y + ry * 0.05))
                out.append(p)
            }
        }
        return out
    }

    static func muzzle(R: CGFloat, face f: CatFace) -> Path {
        Path(ellipseIn: CGRect(x: f.dx - 0.34 * R * f.squash, y: f.dy + 0.24 * R,
                               width: 0.68 * R * f.squash, height: 0.46 * R))
    }

    static func nose(R: CGFloat, face f: CatFace) -> Path {
        let ny = f.dy + 0.34 * R, nw = 0.10 * R * f.squash
        var p = Path()
        p.move(to: CGPoint(x: f.dx - nw, y: ny))
        p.addLine(to: CGPoint(x: f.dx + nw, y: ny))
        p.addLine(to: CGPoint(x: f.dx, y: ny + 0.08 * R))
        p.closeSubpath()
        return p
    }

    static func mouth(R: CGFloat, face f: CatFace) -> Path {
        let my = f.dy + 0.34 * R + 0.08 * R
        let w = 0.13 * R * f.squash, c = 0.06 * R * f.squash
        var p = Path()
        p.move(to: CGPoint(x: f.dx, y: my))
        p.addLine(to: CGPoint(x: f.dx, y: my + 0.05 * R))
        p.addQuadCurve(to: CGPoint(x: f.dx - w, y: my + 0.06 * R), control: CGPoint(x: f.dx - c, y: my + 0.14 * R))
        p.move(to: CGPoint(x: f.dx, y: my + 0.05 * R))
        p.addQuadCurve(to: CGPoint(x: f.dx + w, y: my + 0.06 * R), control: CGPoint(x: f.dx + c, y: my + 0.14 * R))
        return p
    }

    static func whiskers(R: CGFloat, face f: CatFace, time: CGFloat) -> [Path] {
        var out: [Path] = []
        for s in [CGFloat(-1), 1] {
            for i in 0..<3 {
                let y0 = f.dy + (0.42 + CGFloat(i) * 0.07) * R
                let twitch = sin(time * 1.7 + CGFloat(i)) * 0.012 * R
                var p = Path()
                p.move(to: CGPoint(x: f.dx + s * 0.30 * R, y: y0))
                p.addLine(to: CGPoint(x: f.dx + s * 0.98 * R, y: y0 + (CGFloat(i) - 1) * 0.09 * R + twitch))
                out.append(p)
            }
        }
        return out
    }
}

// MARK: - Painting (SwiftUI Canvas)

enum CatPainter {
    static func fillBody(_ ctx: GraphicsContext, path: Path, fur: CatFur, from: CGPoint, to: CGPoint) {
        var c = ctx
        c.fill(path, with: .linearGradient(Gradient(colors: [fur.top.color, fur.bottom.color]),
                                           startPoint: from, endPoint: to))
    }

    /// Ears and tail — drawn before the body so the body covers their roots.
    static func drawBehind(_ ctx: GraphicsContext, R: CGFloat, fur: CatFur, fade: CGFloat, time: CGFloat,
                           lean: CGFloat = 0, droop: CGFloat = 0, wagSpeed: CGFloat = 2.6) {
        guard fade > 0.01 else { return }
        var c = ctx
        c.opacity = Double(fade)
        let flick = CatShape.flick(R: R, time: time)

        for s in [CGFloat(-1), 1] {
            let (outer, inner) = CatShape.ear(side: s, R: R, lean: lean, droop: droop, tipShift: s > 0 ? flick : 0)
            c.stroke(outer, with: .color(fur.bottom.color),
                     style: StrokeStyle(lineWidth: R * 0.14, lineCap: .round, lineJoin: .round))
            c.fill(outer, with: .linearGradient(Gradient(colors: [fur.top.color, fur.bottom.color]),
                                                startPoint: CGPoint(x: 0, y: -1.2 * R),
                                                endPoint: CGPoint(x: 0, y: -0.4 * R)))
            c.stroke(inner, with: .color(fur.innerEar.color),
                     style: StrokeStyle(lineWidth: R * 0.08, lineCap: .round, lineJoin: .round))
            c.fill(inner, with: .color(fur.innerEar.color))
        }

        let tail = CatShape.tail(R: R, wag: sin(time * wagSpeed) * 0.14 * R)
        c.stroke(tail, with: .color(fur.stripe.color), style: StrokeStyle(lineWidth: R * 0.30, lineCap: .round))
        c.stroke(tail, with: .color(fur.bottom.color), style: StrokeStyle(lineWidth: R * 0.22, lineCap: .round))
    }

    /// Tabby stripes, clipped to the body.
    static func drawStripes(_ ctx: GraphicsContext, path: Path, R: CGFloat, rx: CGFloat, ry: CGFloat,
                            fur: CatFur, dx: CGFloat, alpha: CGFloat) {
        var c = ctx
        c.clip(to: path)
        c.opacity = Double(alpha)
        let color = GraphicsContext.Shading.color(fur.stripe.color.opacity(0.85))
        for p in CatShape.foreheadStripes(R: R, ry: ry, dx: dx) {
            c.stroke(p, with: color, style: StrokeStyle(lineWidth: R * 0.09, lineCap: .round))
        }
        for p in CatShape.cheekStripes(rx: rx, ry: ry, dx: dx) {
            c.stroke(p, with: color, style: StrokeStyle(lineWidth: R * 0.08, lineCap: .round))
        }
    }

    /// Cream muzzle, nose and mouth (before the eyes), clipped to the body.
    static func drawMuzzle(_ ctx: GraphicsContext, path: Path, R: CGFloat, fur: CatFur,
                           face: CatFace, alpha: CGFloat) {
        var c = ctx
        c.clip(to: path)
        c.opacity = Double(alpha)
        c.fill(CatShape.muzzle(R: R, face: face), with: .color(fur.cream.color))
        let nose = CatShape.nose(R: R, face: face)
        c.fill(nose, with: .color(fur.nose.color))
        c.stroke(nose, with: .color(fur.nose.color), style: StrokeStyle(lineWidth: R * 0.03, lineJoin: .round))
        c.stroke(CatShape.mouth(R: R, face: face), with: .color(fur.mouth.color),
                 style: StrokeStyle(lineWidth: max(1, R * 0.025), lineCap: .round))
    }

    /// Whiskers extend past the body, so they use the unclipped context (after the eyes).
    static func drawWhiskers(_ ctx: GraphicsContext, R: CGFloat, face: CatFace, time: CGFloat, alpha: CGFloat) {
        var c = ctx
        c.opacity = Double(alpha)
        for p in CatShape.whiskers(R: R, face: face, time: time) {
            c.stroke(p, with: .color(Color.white.opacity(0.9)),
                     style: StrokeStyle(lineWidth: max(1, R * 0.02), lineCap: .round))
        }
    }
}

// MARK: - BotEngine glue

extension BotEngine {

    var isCatActive: Bool { character == .cat }

    /// Mini bots (integration pills) keep their brand colour instead of the default orange.
    private var catFur: CatFur {
        if isMini, let bc = bodyColor { return .tinted(bc) }
        return .orange
    }

    func drawCatBehind(ctx: GraphicsContext, R: CGFloat) {
        let droop: CGFloat = (state == .sleeping) ? 0.16 : 0
        CatPainter.drawBehind(ctx, R: R, fur: catFur, fade: 1 - min(1, morph * 2),
                              time: CGFloat(CACurrentMediaTime()),
                              lean: sin(yaw) * 0.10 * R, droop: droop,
                              wagSpeed: state == .sleeping ? 0.9 : 2.6)
    }

    /// Fur with tabby stripes. State colour is kept as a light tint so states stay readable.
    func drawCatBody(ctx: GraphicsContext, path: Path, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        var c = ctx
        CatPainter.fillBody(c, path: path, fur: catFur,
                            from: CGPoint(x: rx * 0.5, y: -ry * 0.9), to: CGPoint(x: -rx * 0.4, y: ry * 0.95))

        // A focused integration's brand colour (not the default off-white) lightly tints the fur
        if !isMini, let bc = bodyColor, let comps = bc.components, comps.count >= 3,
           min(comps[0], comps[1], comps[2]) < 0.85 {
            c.fill(path, with: .color(Color(cgColor: bc).opacity(0.35 * Double(1 - morph))))
        }

        let effectiveTint = tint * (1 - morph) * 0.4
        if effectiveTint > 0.01 {
            let tc = Color(red: col.0, green: col.1, blue: col.2)
            c.fill(path, with: .linearGradient(
                Gradient(stops: [.init(color: tc.opacity(Double(effectiveTint)), location: 0),
                                 .init(color: tc.opacity(0), location: 1)]),
                startPoint: CGPoint(x: 0, y: ry), endPoint: CGPoint(x: 0, y: -ry)))
        }

        if morph < 0.5 {
            CatPainter.drawStripes(c, path: path, R: R, rx: rx, ry: ry, fur: catFur,
                                   dx: sin(yaw) * rx * 0.5, alpha: 1 - morph * 2)
        }

        c.fill(path, with: .radialGradient(
            Gradient(stops: [.init(color: .clear, location: 0),
                             .init(color: .clear, location: 0.6),
                             .init(color: Color.black.opacity(0.18), location: 1)]),
            center: .zero, startRadius: R * 0.15, endRadius: R * 1.25))
        c.fill(path, with: .radialGradient(
            Gradient(stops: [.init(color: Color.white.opacity(0.35), location: 0),
                             .init(color: .clear, location: 1)]),
            center: CGPoint(x: rx * 0.34, y: -ry * 0.46), startRadius: 0, endRadius: R * 0.42))
    }

    func drawCatMuzzle(ctx: GraphicsContext, path: Path, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard morph < 0.5 else { return }
        CatPainter.drawMuzzle(ctx, path: path, R: R, fur: catFur, face: catFace(rx: rx, ry: ry), alpha: 1 - morph * 2)
    }

    func drawCatWhiskers(ctx: GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard morph < 0.3 else { return }
        CatPainter.drawWhiskers(ctx, R: R, face: catFace(rx: rx, ry: ry),
                                time: CGFloat(CACurrentMediaTime()), alpha: 1 - morph / 0.3)
    }

    private func catFace(rx: CGFloat, ry: CGFloat) -> CatFace {
        CatFace(dx: sin(yaw) * rx * 0.85, dy: -sin(pitch + roll) * ry * 0.35, squash: max(0.45, cos(yaw)))
    }
}
