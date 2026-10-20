import SwiftUI

/// Blob's colors, shared by the Mac and iPhone apps.
enum BuddyColors {
    static let cyan = Color(red: 0.0, green: 0.86, blue: 1.0)
    static let light = Color(red: 0.72, green: 1.0, blue: 1.0)
    static let deep = Color(red: 0.0, green: 0.48, blue: 0.70)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let red = Color(red: 1.0, green: 0.35, blue: 0.4)
}

/// What Blob is feeling. Drives the eyes, arms, glow and body motion.
enum BlobMood: Equatable {
    case sleepy, idle, curious, listening, thinking, speaking, happy, asking, error
}

/// Blob v2: a wobbly cyan gumdrop with living light inside, a dark glass face screen,
/// and glowing eyes that carry all the emotion (inspired by EVE, Copilot's Mico and the ChatGPT voice orb).
struct BlobCharacter: View {
    var mood: BlobMood
    var level: CGFloat
    var look: CGPoint
    /// Draw a single still frame at this time instead of animating (used to render the app icon).
    var fixedTime: Double? = nil
    /// Stop animating entirely (Blob hidden, display asleep).
    var paused = false
    /// Tucked into the corner (mostly off-screen): animate slowly.
    var tucked = false

    private var tint: Color {
        switch mood {
        case .error: return BuddyColors.red
        case .asking: return BuddyColors.amber
        default: return BuddyColors.cyan
        }
    }

    private func glow(_ t: Double) -> Double {
        switch mood {
        case .sleepy: return 0.22 + sin(t * 0.9) * 0.06
        case .idle: return 0.45
        case .curious: return 0.7
        case .listening: return 0.8 + Double(level) * 0.6
        case .thinking: return 0.65 + sin(t * 3.2) * 0.25
        case .speaking: return 0.7 + Double(level) * 0.5
        case .happy: return 1.0
        case .asking: return 0.85
        case .error: return 0.8
        }
    }

    var body: some View {
        if let fixedTime {
            frame(t: fixedTime)
        } else {
            // Battery: 60 fps only while Blob is doing something; 20 fps at rest, 8 fps asleep, 0 when hidden.
            let fps: Double = mood == .sleepy ? 6 : tucked ? 8 : (mood == .idle || mood == .curious) ? 15 : 60
            TimelineView(.animation(minimumInterval: 1.0 / fps, paused: paused)) { ctx in frame(t: ctx.date.timeIntervalSinceReferenceDate) }
        }
    }

    private func frame(t: Double) -> some View {
            GeometryReader { geo in
                let s = min(geo.size.width, geo.size.height)
                let g = glow(t)
                let energy = (mood == .listening || mood == .speaking) ? level : 0
                let breathe = mood == .sleepy ? 1 + CGFloat(sin(t * 0.9)) * 0.03 : 1 + CGFloat(sin(t * 2.0)) * 0.012
                let bob = mood == .sleepy ? 0 : CGFloat(sin(t * 1.6)) * s * 0.022 - (mood == .happy ? abs(CGFloat(sin(t * 7))) * s * 0.06 : 0)

                ZStack {
                    // Halo
                    Circle()
                        .fill(RadialGradient(colors: [tint.opacity(0.55 * g), tint.opacity(0.16 * g), .clear],
                                             center: .center, startRadius: s * 0.18, endRadius: s * 0.95))
                        .frame(width: s * 1.9, height: s * 1.9)
                        .blur(radius: s * 0.065)

                    ZStack {
                        arms(s: s, t: t)
                        body(s: s, t: t, energy: energy)
                        face(s: s, t: t)
                    }
                    .scaleEffect(breathe + energy * 0.08)
                    .rotationEffect(.degrees(tilt(t)))
                    .offset(y: bob)
                    .keyframeAnimator(initialValue: CGSize(width: 1, height: 1), trigger: mood) { content, v in
                        content.scaleEffect(x: v.width, y: v.height, anchor: .bottom)
                    } keyframes: { _ in
                        // Squash & stretch whenever the mood changes.
                        KeyframeTrack(\.width) {
                            SpringKeyframe(1.12, duration: 0.10)
                            SpringKeyframe(0.94, duration: 0.14)
                            SpringKeyframe(1.0, duration: 0.30)
                        }
                        KeyframeTrack(\.height) {
                            SpringKeyframe(0.88, duration: 0.10)
                            SpringKeyframe(1.07, duration: 0.14)
                            SpringKeyframe(1.0, duration: 0.30)
                        }
                    }

                    if mood == .sleepy { snores(s: s, t: t) }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .shadow(color: tint.opacity(0.85 * min(g, 1)), radius: s * (0.1 + energy * 0.15))
                .shadow(color: tint.opacity(0.45 * min(g, 1)), radius: s * (0.26 + energy * 0.22))
                // Render the whole character (glow included) on the GPU in one pass instead of on the CPU.
                // The padding makes room for the glow, which reaches well past Blob's frame.
                .padding(s * 0.7)
                .drawingGroup()
                .padding(-s * 0.7)
            }
    }

    private func tilt(_ t: Double) -> Double {
        switch mood {
        case .curious: return Double(look.x) * 9
        case .listening: return -6 + sin(t * 1.5) * 2      // leans in toward the screen
        case .thinking: return sin(t * 0.8) * 5
        case .asking: return 8
        case .error: return sin(t * 30) * 2.5
        case .sleepy: return -10
        default: return 0
        }
    }

    // MARK: Body

    private func body(s: CGFloat, t: Double, energy: CGFloat) -> some View {
        let wobble: CGFloat = mood == .sleepy ? 0.012 : 0.025 + energy * 0.05 + (mood == .thinking ? 0.02 : 0)
        let shape = BlobShape(t: t, wobble: wobble)
        let swirl = mood == .thinking ? 2.6 : (mood == .sleepy ? 0.25 : 0.7)
        return ZStack {
            shape.fill(RadialGradient(colors: [BuddyColors.light, BuddyColors.cyan, BuddyColors.deep],
                                      center: UnitPoint(x: 0.36, y: 0.28), startRadius: s * 0.02, endRadius: s * 0.62))
            // Living light moving inside the body
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let a = t * swirl * (i == 1 ? -1 : 1) + Double(i) * 2.1
                    Circle()
                        .fill(i == 0 ? Color.white.opacity(0.55) : BuddyColors.light.opacity(0.6))
                        .frame(width: s * (0.3 + energy * 0.2), height: s * (0.3 + energy * 0.2))
                        .offset(x: CGFloat(cos(a)) * s * 0.2, y: CGFloat(sin(a * 1.3)) * s * 0.16 + s * 0.12)
                        .blur(radius: s * 0.09)
                }
            }
            .blendMode(.plusLighter)
            .clipShape(shape)
            // Rim light along the base
            shape.stroke(LinearGradient(colors: [.clear, BuddyColors.light.opacity(0.8)], startPoint: .top, endPoint: .bottom), lineWidth: s * 0.02)
            // Gloss
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.34, height: s * 0.15)
                .rotationEffect(.degrees(-24))
                .offset(x: -s * 0.18, y: -s * 0.29)
                .blur(radius: s * 0.013)
            if mood == .error { shape.fill(BuddyColors.red.opacity(0.3)) }
        }
        .frame(width: s * 0.82, height: s * 0.8)
    }

    // MARK: Face

    private func face(s: CGFloat, t: Double) -> some View {
        let vw = s * 0.56, vh = s * 0.32
        return ZStack {
            RoundedRectangle(cornerRadius: vh * 0.48, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.05, green: 0.12, blue: 0.19), Color(red: 0.0, green: 0.03, blue: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: vh * 0.48, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [BuddyColors.deep.opacity(0.9), BuddyColors.light.opacity(0.5)], startPoint: .top, endPoint: .bottom), lineWidth: max(1, s * 0.011)))
            Canvas { ctx, size in drawEyes(ctx, size: size, t: t) }
            // Glass reflection
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: vw * 0.5, height: vh * 0.22)
                .offset(x: -vw * 0.16, y: -vh * 0.3)
        }
        .frame(width: vw, height: vh)
        .offset(x: mood == .curious ? look.x * s * 0.02 : 0, y: -s * 0.07)
    }

    private func blink(_ t: Double) -> CGFloat {
        let cycle = t.truncatingRemainder(dividingBy: 4.3)
        let k: Double
        if cycle < 0.13 { k = abs(cycle - 0.065) / 0.065 }
        else if Int(t / 4.3) % 3 == 0, cycle > 0.25, cycle < 0.38 { k = abs(cycle - 0.315) / 0.065 }   // occasional double blink
        else { k = 1 }
        return CGFloat(max(0.08, k))
    }

    private func drawEyes(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, h = size.height
        let ew = w * 0.13, eh = h * 0.5
        let cy = h * 0.5
        let xs = [w * 0.31, w * 0.69]
        var color = BuddyColors.light
        if mood == .asking { color = Color(red: 1, green: 0.85, blue: 0.5) }
        if mood == .error { color = Color(red: 1, green: 0.6, blue: 0.62) }

        var lookX = look.x * w * 0.06, lookY = look.y * h * 0.1
        if mood == .listening { lookX *= 0.4; lookY *= 0.4 }

        var paths: [Path] = []
        var strokes: [Path] = []
        let b = blink(t)

        func pill(_ cx: CGFloat, _ cy: CGFloat, _ pw: CGFloat, _ ph: CGFloat) -> Path {
            Path(roundedRect: CGRect(x: cx - pw / 2, y: cy - ph / 2, width: pw, height: ph), cornerRadius: pw / 2)
        }

        switch mood {
        case .idle, .curious:
            let grow: CGFloat = mood == .curious ? 1.15 : 1
            for x in xs { paths.append(pill(x + lookX, cy + lookY, ew * grow, eh * grow * b)) }
        case .listening:
            let d = eh * (0.82 + level * 0.18)
            for x in xs { paths.append(Path(ellipseIn: CGRect(x: x + lookX - d / 2, y: cy + lookY - d / 2 * b, width: d, height: d * b))) }
        case .thinking:
            let dx = CGFloat(sin(t * 0.8)) * w * 0.05
            paths.append(pill(xs[0] + dx, cy - h * 0.1, ew, eh * 0.45))           // squint
            paths.append(pill(xs[1] + dx, cy - h * 0.12, ew, eh * 0.8 * b))
        case .speaking:
            let hop = -level * h * 0.06
            for x in xs { paths.append(pill(x + lookX * 0.5, h * 0.4 + hop, ew, eh * 0.7 * b)) }
            let mw = w * (0.1 + level * 0.1), mh = h * (0.07 + level * 0.16)
            paths.append(Path(roundedRect: CGRect(x: w / 2 - mw / 2, y: h * 0.8 - mh / 2, width: mw, height: mh), cornerRadius: min(mw, mh) / 2))
        case .happy:
            for x in xs {
                var p = Path()
                p.move(to: CGPoint(x: x - ew * 0.9, y: cy + eh * 0.12))
                p.addQuadCurve(to: CGPoint(x: x + ew * 0.9, y: cy + eh * 0.12), control: CGPoint(x: x, y: cy - eh * 0.6))
                strokes.append(p)
            }
        case .sleepy:
            for x in xs {
                var p = Path()
                p.move(to: CGPoint(x: x - ew * 0.8, y: cy))
                p.addQuadCurve(to: CGPoint(x: x + ew * 0.8, y: cy), control: CGPoint(x: x, y: cy + eh * 0.28))
                strokes.append(p)
            }
        case .asking:
            paths.append(pill(xs[0], cy + h * 0.04, ew, eh * 0.75 * b))
            paths.append(pill(xs[1], cy - h * 0.06, ew * 1.1, eh * 1.05 * b))    // one "raised eyebrow" eye
        case .error:
            for (i, x) in xs.enumerated() {
                let dir: CGFloat = i == 0 ? 1 : -1
                var p = Path()
                p.move(to: CGPoint(x: x - dir * ew * 0.7, y: cy - eh * 0.35))
                p.addLine(to: CGPoint(x: x + dir * ew * 0.6, y: cy))
                p.addLine(to: CGPoint(x: x - dir * ew * 0.7, y: cy + eh * 0.35))
                strokes.append(p)
            }
        }

        let lineWidth = ew * 0.55
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        // Bloom
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: ew * 0.6))
            for p in paths { layer.fill(p, with: .color(BuddyColors.cyan)) }
            for p in strokes { layer.stroke(p, with: .color(BuddyColors.cyan), style: style) }
        }
        // Core
        for p in paths { ctx.fill(p, with: .color(color)) }
        for p in strokes { ctx.stroke(p, with: .color(color), style: style) }
    }

    // MARK: Arms

    private func arms(s: CGFloat, t: Double) -> some View {
        ZStack {
            arm(s: s, t: t, left: true)
            arm(s: s, t: t, left: false)
        }
    }

    private func arm(s: CGFloat, t: Double, left: Bool) -> some View {
        let side: CGFloat = left ? -1 : 1
        var lift: Double
        switch mood {
        case .curious: lift = left ? 0 : 55 + sin(t * 10) * 18                 // waves hello
        case .listening: lift = 30 + sin(t * 3) * 5
        case .thinking: lift = left ? 0 : 70                                    // hand to chin
        case .speaking: lift = 10 + sin(t * 5 + (left ? 0 : 1.6)) * 12
        case .happy: lift = 80 + sin(t * 14) * 10                               // cheer
        case .asking: lift = left ? 10 : 40
        case .sleepy: lift = -10
        default: lift = sin(t * 1.6 + (left ? 0 : 1)) * 5
        }
        let gradient = RadialGradient(colors: [BuddyColors.light, BuddyColors.cyan, BuddyColors.deep],
                                      center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: s * 0.13)
        let angle: Double = Double(side) * (25 + lift)
        return Capsule()
            .fill(gradient)
            .frame(width: s * 0.15, height: s * 0.26)
            .rotationEffect(.degrees(angle), anchor: UnitPoint(x: 0.5, y: 0.15))
            .offset(x: side * s * 0.36, y: s * 0.16)
    }

    private func snores(s: CGFloat, t: Double) -> some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                let p = (t * 0.35 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                Text("z")
                    .font(.system(size: s * (0.12 + CGFloat(p) * 0.08), weight: .heavy, design: .rounded))
                    .foregroundStyle(BuddyColors.light)
                    .opacity(sin(p * .pi) * 0.9)
                    .offset(x: -s * 0.3 - CGFloat(p) * s * 0.15, y: -s * 0.38 - CGFloat(p) * s * 0.22)
            }
        }
    }
}

/// An organic gumdrop: a soft circle, slightly wider and flatter at the base, whose edge gently wobbles.
struct BlobShape: Shape {
    var t: Double
    var wobble: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2, ry = rect.height / 2
        let n = 10
        let pts: [CGPoint] = (0..<n).map { i in
            let a = Double(i) / Double(n) * 2 * .pi - .pi / 2
            let w = 1 + wobble * CGFloat(sin(t * (1.3 + Double(i % 3) * 0.45) + Double(i) * 1.7))
            var x = CGFloat(cos(a)), y = CGFloat(sin(a))
            if y > 0 { x *= 1 + 0.05 * y; y *= 0.96 }
            return CGPoint(x: c.x + x * rx * w, y: c.y + y * ry * w)
        }
        var p = Path()
        p.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
        p.closeSubpath()
        return p
    }
}

