import AppKit
import BaobabL10n
import QuartzCore

/// Vue superposée au graphique le temps d'un effet : transparente aux clics, animée par l'horloge
/// d'affichage, puis retirée. Rien ne tourne une fois l'effet terminé.
class EffectOverlay: NSView {
    let duration: Double
    private var link: CADisplayLink?
    private var started = CACurrentMediaTime()

    init(duration: Double) {
        self.duration = duration
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var elapsed: Double { CACurrentMediaTime() - started }

    func start() {
        started = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if elapsed >= duration {
            link.invalidate()
            self.link = nil
            removeFromSuperview()
        } else {
            needsDisplay = true
        }
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    static func text(_ string: String, at point: CGPoint, font: NSFont, color: NSColor, centered: Bool = true, shadow: Bool = false) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if shadow {
            let textShadow = NSShadow()
            textShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            textShadow.shadowBlurRadius = 3
            attributes[.shadow] = textShadow
        }
        let size = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(at: CGPoint(x: centered ? point.x - size.width / 2 : point.x, y: point.y - size.height / 2), withAttributes: attributes)
    }
}

// MARK: - Le baobab pousse (H)

/// Un baobab sort de terre : tronc, une branche par grand dossier (épaisse selon sa taille),
/// feuillage aux couleurs des types de fichiers, puis il s'efface sur le graphique.
final class BaobabOverlay: EffectOverlay {
    /// Appelé quand l'arbre commence à s'effacer : le graphique se construit dessous.
    var onFading: (() -> Void)?

    private struct Branch {
        let name: String
        let size: Int64
        let weight: CGFloat
        let colors: [NSColor]
    }

    private let branches: [Branch]
    private let fadeStart = 2.6
    private var faded = false
    private static let bark = NSColor(hex: "#A8774A")

    init(root: DiskNode) {
        let kids = (root.children ?? []).filter { $0.size > 0 }.prefix(6)
        let largest = Double(max(kids.first?.size ?? 1, 1))
        branches = kids.map { kid in
            let colors = DiskCategory.allCases.map { ($0, kid.size(of: $0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3).map { $0.0.color }
            return Branch(name: kid.name, size: kid.size, weight: CGFloat((Double(kid.size) / largest).squareRoot()),
                          colors: colors.isEmpty ? [DiskCategory.other.color] : Array(colors))
        }
        super.init(duration: 3.05)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let t = elapsed
        if t >= fadeStart, !faded {
            faded = true
            onFading?()
        }
        let alpha = CGFloat(1 - Ease.clamp((t - fadeStart) / (duration - fadeStart)))
        context.setAlpha(alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let w = bounds.width, h = bounds.height
        let ground = h - 22, cx = w / 2
        var random = SeededRandom(42)
        // Ombre au sol.
        NSColor.separatorColor.withAlphaComponent(CGFloat(Ease.clamp(t / 0.3)) * 0.35).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - w * 0.3, y: ground - 3, width: w * 0.6, height: 14)).fill()
        // Tronc.
        let trunkHeight = h * 0.38 * CGFloat(Ease.out(Ease.clamp(t / 0.8)))
        let base = min(w * 0.075, 64), top = min(w * 0.045, 38)
        let topY = ground - trunkHeight
        let trunk = CGMutablePath()
        trunk.move(to: CGPoint(x: cx - base, y: ground))
        trunk.addCurve(to: CGPoint(x: cx - top, y: topY), control1: CGPoint(x: cx - base * 1.1, y: ground - trunkHeight * 0.4),
                       control2: CGPoint(x: cx - top * 1.3, y: topY + trunkHeight * 0.3))
        trunk.addLine(to: CGPoint(x: cx + top, y: topY))
        trunk.addCurve(to: CGPoint(x: cx + base, y: ground), control1: CGPoint(x: cx + top * 1.3, y: topY + trunkHeight * 0.3),
                       control2: CGPoint(x: cx + base * 1.1, y: ground - trunkHeight * 0.4))
        trunk.closeSubpath()
        context.addPath(trunk)
        context.setFillColor(Self.bark.cgColor)
        context.fillPath()
        // Branches : une par grand dossier, en éventail d'autant plus large qu'elles sont nombreuses.
        let count = CGFloat(branches.count)
        let spread = min(2.3, 0.62 * (count - 1))
        // La plus grosse branche au centre, les suivantes alternativement de part et d'autre.
        let slots = (0..<branches.count).map { count > 1 ? CGFloat($0) / (count - 1) - 0.5 : 0 }.sorted { abs($0) < abs($1) }
        var tips: [CGPoint] = []
        for (index, branch) in branches.enumerated() {
            let fraction = slots[index]
            let i = (fraction + 0.5) * (count - 1)
            let angle = -CGFloat.pi / 2 + fraction * spread + CGFloat(random.next() - 0.5) * 0.08
            let length = (h * 0.17 + h * 0.13 * branch.weight) * CGFloat(0.9 + random.next() * 0.2)
            let p = CGFloat(Ease.out(Ease.clamp((t - 0.55 - Double(index) * 0.06) / 0.6)))
            let start = CGPoint(x: cx + (i - (count - 1) / 2) * top * 0.3, y: topY + 2)
            let tip = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            tips.append(tip)
            guard p > 0 else { continue }
            let end = CGPoint(x: start.x + cos(angle) * length * p, y: start.y + sin(angle) * length * p)
            context.move(to: start)
            context.addQuadCurve(to: end, control: CGPoint(x: start.x + cos(angle) * length * p * 0.3, y: start.y - length * p * 0.55))
            context.setStrokeColor(Self.bark.cgColor)
            context.setLineCap(.round)
            context.setLineWidth(3 + 9 * branch.weight)
            context.strokePath()
        }
        // Feuillage aux couleurs des types de fichiers de chaque branche.
        for (index, branch) in branches.enumerated() {
            let tip = tips[index]
            let leaves = 7 + Int(20 * branch.weight), spread = 12 + 30 * branch.weight
            for leaf in 0..<leaves {
                let angle = random.next() * 2 * .pi, distance = random.next().squareRoot() * Double(spread)
                let center = CGPoint(x: tip.x + CGFloat(cos(angle) * distance * 1.25), y: tip.y + CGFloat(sin(angle) * distance * 0.7) - 4)
                let delay = 1.25 + Double(index) * 0.07 + random.next() * 0.35
                let radius = CGFloat(4 + random.next() * 5) * CGFloat(Ease.back(Ease.clamp((t - delay) / 0.4)))
                guard radius > 0 else { continue }
                branch.colors[leaf % branch.colors.count].withAlphaComponent(0.92).setFill()
                NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            }
        }
        // Noms des trois plus grosses branches (un nom qui en chevaucherait un autre est omis).
        let labels = CGFloat(Ease.clamp((t - 2.0) / 0.4))
        guard labels > 0 else { return }
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        var placed: [CGRect] = []
        for (index, branch) in branches.prefix(3).enumerated() {
            let text = "\(branch.name) · \(Format.size(branch.size))"
            let center = CGPoint(x: tips[index].x, y: tips[index].y - 22 - 30 * branch.weight)
            let size = (text as NSString).size(withAttributes: [.font: font])
            let frame = CGRect(x: center.x - size.width / 2 - 4, y: center.y - size.height / 2, width: size.width + 8, height: size.height)
            guard !placed.contains(where: { $0.intersects(frame) }) else { continue }
            placed.append(frame)
            EffectOverlay.text(text, at: center, font: font, color: NSColor.labelColor.withAlphaComponent(labels))
        }
    }
}

// MARK: - Pluie de feuilles (I)

/// Après avoir libéré au moins 1 Go : des feuilles tombent en virevoltant et le compteur défile.
final class LeavesOverlay: EffectOverlay {
    private let freed: Int64

    init(freed: Int64) {
        self.freed = freed
        super.init(duration: 3.0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let t = elapsed
        let w = bounds.width, h = bounds.height
        let fadeOut = CGFloat(1 - Ease.clamp((t - 2.6) / 0.4))
        var random = SeededRandom(11)
        let colors = DiskCategory.allCases.map(\.color)
        for _ in 0..<46 {
            let x0 = random.next() * Double(w), delay = random.next() * 0.9, speed = 60 + random.next() * 70
            let amplitude = 10 + random.next() * 22, frequency = 2 + random.next() * 2.5, spin = (random.next() - 0.5) * 5
            let size = CGFloat(6 + random.next() * 6), color = colors[Int(random.next() * Double(colors.count)) % colors.count]
            let s = t - delay
            guard s > 0 else { continue }
            let y = -16 + s * speed * Double(max(1, h / 300)), x = x0 + sin(s * frequency) * amplitude
            guard y < Double(h) + 16 else { continue }
            context.saveGState()
            context.setAlpha(fadeOut)
            context.translateBy(x: CGFloat(x), y: CGFloat(y))
            context.rotate(by: CGFloat(spin * s + sin(s * frequency) * 0.6))
            let leaf = CGMutablePath()
            leaf.move(to: CGPoint(x: -size, y: 0))
            leaf.addQuadCurve(to: CGPoint(x: size, y: 0), control: CGPoint(x: 0, y: -size * 0.75))
            leaf.addQuadCurve(to: CGPoint(x: -size, y: 0), control: CGPoint(x: 0, y: size * 0.75))
            context.addPath(leaf)
            context.setFillColor(color.cgColor)
            context.fillPath()
            context.move(to: CGPoint(x: -size * 0.8, y: 0))
            context.addLine(to: CGPoint(x: size * 0.8, y: 0))
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(0.8)
            context.strokePath()
            context.restoreGState()
        }
        // Carte du compteur, en haut.
        let appear = Ease.out(Ease.clamp((t - 0.1) / 0.4))
        guard appear > 0 else { return }
        let width = min(w - 40, 250)
        let card = CGRect(x: (w - width) / 2, y: 18 - CGFloat(1 - appear) * 20, width: width, height: 58)
        context.saveGState()
        context.setAlpha(CGFloat(appear) * fadeOut)
        context.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        context.addPath(CGPath(roundedRect: card, cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        context.fillPath()
        context.restoreGState()
        let count = Int64(Double(freed) * Ease.out(Ease.clamp((t - 0.2) / 1.2)))
        let alpha = CGFloat(appear) * fadeOut
        EffectOverlay.text(L("\(Format.size(count)) libérés"), at: CGPoint(x: card.midX, y: card.minY + 22),
                           font: .systemFont(ofSize: 19, weight: .bold), color: DiskCategory.images.color.withAlphaComponent(alpha))
        EffectOverlay.text(L("Le disque respire un peu mieux"), at: CGPoint(x: card.midX, y: card.minY + 43),
                           font: .systemFont(ofSize: 11.5), color: NSColor.secondaryLabelColor.withAlphaComponent(alpha))
    }
}
