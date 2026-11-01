import AppKit
import QuartzCore

/// Effets d'animation du graphique. L'app hôte choisit lesquels jouent ; par défaut aucun
/// (iExplorer garde son comportement tant qu'il ne fournit pas `isEnabled`).
public enum DiskEffect: String, CaseIterable, Sendable {
    /// Le graphique se construit à la fin d'une analyse (blocs qui grandissent, rangées qui se déroulent).
    case growth
    /// Zoom dans un dossier, dézoom en remontant.
    case zoom
    /// Les anneaux du soleil et de l'anneau se déploient dans le sens horaire.
    case unfold
    /// Changement de représentation ou de couleurs : les blocs glissent vers leur nouvelle place.
    case morph
    /// Le bloc mis à la corbeille s'effrite, ses voisins prennent sa place.
    case crumble
    /// Pendant l'analyse, chaque dossier terminé prend sa place dans le graphique.
    case liveScan
    /// Un baobab pousse à la fin d'une analyse (une branche par grand dossier).
    case baobab
    /// Pluie de feuilles et compteur après avoir libéré au moins 1 Go.
    case leaves
}

public enum DiskEffects {
    /// Fourni par l'app hôte.
    @MainActor public static var isEnabled: (DiskEffect) -> Bool = { _ in false }

    /// L'effet joue-t-il ? Jamais si macOS demande de réduire les animations.
    @MainActor static func on(_ effect: DiskEffect) -> Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && isEnabled(effect)
    }
}

/// Cause d'un changement de racine, qui décide de l'animation.
enum RootChange {
    case none
    /// Fin d'une analyse.
    case reveal
    /// Fin d'une analyse, avec le baobab avant le graphique.
    case baobab
    /// Navigation (descendre, remonter, historique).
    case navigate
    /// Analyse en direct : un dossier de plus est terminé.
    case live
    /// Représentation ou couleurs changées.
    case restyle
    /// Élément mis à la corbeille.
    case trash(DiskNode)
}

extension DiskChartStyle {
    /// Représentations circulaires (secteurs plutôt que rectangles).
    var isRadial: Bool { self == .sunburst || self == .baobab || self == .donut }
}

/// Image du graphique et emplacement de ses formes, pour animer le passage d'un état à l'autre.
struct ChartSnapshot {
    let image: CGImage
    let scale: CGFloat
    let size: CGSize
    let style: DiskChartStyle
    let shapes: [DiskChartView.Shape]
    let center: CGPoint
    let centerRadius: CGFloat
    let root: DiskNode?
    /// Bloc hachuré de l'analyse en direct.
    let pendingRect: CGRect?
    /// Blocs de premier niveau (et racine de la partition) : ce qui glisse d'un état à l'autre.
    let blocks: [(id: ObjectIdentifier, rect: CGRect)]

    init(image: CGImage, view: DiskChartView) {
        self.image = image
        size = view.bounds.size
        scale = CGFloat(image.width) / max(1, view.bounds.width)
        style = view.style
        shapes = view.shapes
        center = view.center
        centerRadius = view.centerRadius
        root = view.root
        pendingRect = view.pendingNode.flatMap { pending in view.shapes.first { $0.node === pending }?.rect }
        blocks = style.isRadial || style == .histogram ? [] : view.shapes
            .filter { $0.depth <= 1 && $0.rect.width > 0.5 && $0.rect.height > 0.5 }
            .map { (ObjectIdentifier($0.node), $0.rect) }
    }

    func piece(_ rect: CGRect) -> CGImage? {
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        return image.cropping(to: pixels)
    }

    func rect(of id: ObjectIdentifier) -> CGRect? { blocks.first { $0.id == id }?.rect }

    /// Emplacement du nœud, ou de son ancêtre affiché le plus proche (sans dépasser `stop`).
    func rect(near node: DiskNode, stoppingAt stop: DiskNode?) -> CGRect? {
        var candidate: DiskNode? = node
        while let current = candidate, current !== stop {
            if let shape = shapes.last(where: { $0.node === current }), shape.rect.width > 1, shape.rect.height > 1 { return shape.rect }
            candidate = current.parent
        }
        return nil
    }
}

extension CGContext {
    /// Dessine une image (lignes de haut en bas) dans un rectangle d'une vue retournée.
    func drawImage(_ image: CGImage, in rect: CGRect, alpha: CGFloat = 1) {
        guard alpha > 0.001, rect.width > 0.1, rect.height > 0.1 else { return }
        saveGState()
        setAlpha(alpha)
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}

enum Ease {
    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func out(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func inOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func back(_ t: Double) -> Double { let c = 1.5; return 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2) }
}

func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    let t = CGFloat(t)
    return CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                  width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
}

/// Générateur pseudo-aléatoire reproductible (mêmes éclats, mêmes feuilles à chaque image).
struct SeededRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

/// Animation du graphique, dessinée à partir d'images capturées avant et après le changement :
/// le rendu est exact (textes compris) et chaque image ne coûte que quelques copies de bitmap.
final class ChartTransition {
    enum Reveal { case blocks, rows, bars, unfold, fade }

    struct Debris {
        let image: CGImage
        let rect: CGRect
        let velocity: CGVector
        let spin: CGFloat
        let delay: Double
    }

    enum Kind {
        case reveal(ChartSnapshot, Reveal)
        case fade(from: ChartSnapshot, to: ChartSnapshot)
        case zoom(from: ChartSnapshot, to: ChartSnapshot, focus: CGRect, zoomIn: Bool)
        case pieces(from: ChartSnapshot, to: ChartSnapshot, debris: [Debris], moveDelay: Double, moveDuration: Double)
    }

    let kind: Kind
    let duration: Double
    /// Blocs qui partent en éclats au lieu de s'effacer.
    private let broken: Set<ObjectIdentifier>
    private let start = CACurrentMediaTime()

    init(_ kind: Kind, duration: Double, broken: Set<ObjectIdentifier> = []) {
        self.kind = kind
        self.duration = duration
        self.broken = broken
    }

    var elapsed: Double { CACurrentMediaTime() - start }
    var isFinished: Bool { elapsed >= duration }

    func draw(in context: CGContext, bounds: CGRect) {
        let t = min(elapsed, duration)
        switch kind {
        case let .reveal(snapshot, mode): drawReveal(snapshot, mode, t, context, bounds)
        case let .fade(from, to):
            let e = Ease.inOut(t / duration)
            context.drawImage(from.image, in: bounds, alpha: 1 - e)
            let grow = 0.97 + 0.03 * e
            context.drawImage(to.image, in: bounds.insetBy(dx: bounds.width * (1 - grow) / 2, dy: bounds.height * (1 - grow) / 2), alpha: e)
        case let .zoom(from, to, focus, zoomIn):
            let e = Ease.inOut(t / duration)
            // Rectangle où tomberait toute la vue si `focus` la remplissait.
            let sx = bounds.width / max(1, focus.width), sy = bounds.height / max(1, focus.height)
            let big = CGRect(x: bounds.minX - (focus.minX - bounds.minX) * sx, y: bounds.minY - (focus.minY - bounds.minY) * sy,
                             width: bounds.width * sx, height: bounds.height * sy)
            if zoomIn {
                context.drawImage(from.image, in: lerp(bounds, big, e), alpha: 1 - Ease.clamp((e - 0.4) / 0.6))
                context.drawImage(to.image, in: lerp(focus, bounds, e), alpha: Ease.clamp(e * 1.6))
            } else {
                context.drawImage(to.image, in: lerp(big, bounds, e), alpha: Ease.clamp(e * 1.6))
                context.drawImage(from.image, in: lerp(bounds, focus, e), alpha: 1 - Ease.clamp((e - 0.3) / 0.7))
            }
        case let .pieces(from, to, debris, moveDelay, moveDuration):
            drawPieces(from, to, debris, moveDelay, moveDuration, t, context)
        }
    }

    // MARK: Le graphique se construit (A) ou se déploie (D)

    private func drawReveal(_ snapshot: ChartSnapshot, _ mode: Reveal, _ t: Double, _ context: CGContext, _ bounds: CGRect) {
        switch mode {
        case .blocks:
            var index = 0
            for shape in snapshot.shapes where shape.depth == 1 {
                let delay = min(0.5, Double(index) * 0.04)
                index += 1
                let q = Ease.clamp((t - delay) / 0.5)
                guard q > 0, let piece = snapshot.piece(shape.rect) else { continue }
                let e = CGFloat(Ease.back(q))
                let r = shape.rect
                context.drawImage(piece, in: CGRect(x: r.midX - r.width * e / 2, y: r.midY - r.height * e / 2, width: r.width * e, height: r.height * e),
                                  alpha: CGFloat(Ease.clamp(q * 3)))
            }
        case .rows, .bars:
            // Partition : une rangée par profondeur ; histogramme : une barre (et son texte) par élément.
            var bands: [CGRect] = []
            if mode == .rows {
                let depths = Set(snapshot.shapes.map(\.depth)).sorted()
                for depth in depths {
                    let rows = snapshot.shapes.filter { $0.depth == depth }.map(\.rect)
                    guard let top = rows.map(\.minY).min(), let bottom = rows.map(\.maxY).max() else { continue }
                    bands.append(CGRect(x: 0, y: top - 1, width: bounds.width, height: bottom - top + 2))
                }
            } else {
                bands = snapshot.shapes.map { CGRect(x: 0, y: $0.rect.minY - 4, width: bounds.width, height: $0.rect.height + 8) }
            }
            for (index, band) in bands.enumerated() {
                let q = Ease.out(Ease.clamp((t - Double(index) * (mode == .rows ? 0.12 : 0.035)) / 0.55))
                guard q > 0 else { continue }
                context.saveGState()
                context.clip(to: CGRect(x: band.minX, y: band.minY, width: band.width * CGFloat(q), height: band.height))
                context.drawImage(snapshot.image, in: bounds)
                context.restoreGState()
            }
        case .unfold:
            let rings = Dictionary(grouping: snapshot.shapes.compactMap { shape in shape.arc.map { (shape.depth, $0.r0, $0.r1) } }, by: \.0)
            for depth in rings.keys.sorted() {
                guard let values = rings[depth], let r0 = values.map(\.1).min(), let r1 = values.map(\.2).max() else { continue }
                let sweep = 2 * Double.pi * Ease.out(Ease.clamp((t - Double(depth - 1) * 0.22) / 0.8))
                guard sweep > 0.001 else { continue }
                let path = CGMutablePath()
                path.addArc(center: snapshot.center, radius: r1 + 1, startAngle: -.pi / 2, endAngle: -.pi / 2 + CGFloat(sweep), clockwise: false)
                path.addArc(center: snapshot.center, radius: max(0, r0 - 1), startAngle: -.pi / 2 + CGFloat(sweep), endAngle: -.pi / 2, clockwise: true)
                path.closeSubpath()
                context.saveGState()
                context.addPath(path)
                context.clip()
                context.drawImage(snapshot.image, in: bounds)
                context.restoreGState()
            }
            // Centre (nom, taille) en fondu.
            let r = snapshot.centerRadius + 1
            context.saveGState()
            context.addEllipse(in: CGRect(x: snapshot.center.x - r, y: snapshot.center.y - r, width: r * 2, height: r * 2))
            context.clip()
            context.drawImage(snapshot.image, in: bounds, alpha: CGFloat(Ease.clamp((t - 0.3) / 0.5)))
            context.restoreGState()
        case .fade:
            let e = Ease.out(t / duration)
            let grow = 0.94 + 0.06 * e
            context.drawImage(snapshot.image, in: bounds.insetBy(dx: bounds.width * (1 - grow) / 2, dy: bounds.height * (1 - grow) / 2), alpha: CGFloat(e))
        }
    }

    static func revealDuration(_ snapshot: ChartSnapshot, _ mode: Reveal) -> Double {
        switch mode {
        case .blocks: 0.5 + min(0.5, Double(max(0, snapshot.shapes.filter { $0.depth == 1 }.count - 1)) * 0.04)
        case .rows: 0.55 + Double(Set(snapshot.shapes.map(\.depth)).count) * 0.12
        case .bars: 0.55 + Double(snapshot.shapes.count) * 0.035
        case .unfold: 0.8 + Double((snapshot.shapes.map(\.depth).max() ?? 1) - 1) * 0.22 + 0.1
        case .fade: 0.45
        }
    }

    // MARK: Les blocs glissent (E, G) et la corbeille effrite (F)

    private func drawPieces(_ from: ChartSnapshot, _ to: ChartSnapshot, _ debris: [Debris], _ moveDelay: Double, _ moveDuration: Double,
                            _ t: Double, _ context: CGContext) {
        let e = Ease.inOut(Ease.clamp((t - moveDelay) / moveDuration))
        let kept = Set(to.blocks.map(\.id))
        // Ce qui disparaît (hors éclats) s'efface sur place.
        for block in from.blocks where !kept.contains(block.id) && !broken.contains(block.id) {
            if let piece = from.piece(block.rect) { context.drawImage(piece, in: block.rect, alpha: CGFloat(1 - e)) }
        }
        for block in to.blocks {
            if let old = from.rect(of: block.id) {
                let r = lerp(old, block.rect, e)
                if e < 1, let piece = from.piece(old) { context.drawImage(piece, in: r, alpha: CGFloat(1 - e)) }
                if let piece = to.piece(block.rect) { context.drawImage(piece, in: r, alpha: CGFloat(e)) }
            } else {
                // Nouveau bloc : il sort du bloc hachuré (analyse en direct) ou grandit sur place.
                let origin = from.pendingRect.map { CGRect(x: $0.minX, y: $0.minY, width: 0, height: 0) }
                    ?? CGRect(x: block.rect.midX, y: block.rect.midY, width: 0, height: 0)
                if let piece = to.piece(block.rect) { context.drawImage(piece, in: lerp(origin, block.rect, e), alpha: CGFloat(Ease.clamp(e * 2))) }
            }
        }
        for item in debris {
            let s = CGFloat(max(0, t - item.delay))
            let alpha = 1 - s / 1.0
            guard alpha > 0 else { continue }
            let x = item.rect.midX + item.velocity.dx * s
            let y = item.rect.midY + item.velocity.dy * s + 520 * s * s
            context.saveGState()
            context.translateBy(x: x, y: y)
            context.rotate(by: item.spin * s)
            context.drawImage(item.image, in: CGRect(x: -item.rect.width / 2, y: -item.rect.height / 2, width: item.rect.width, height: item.rect.height), alpha: alpha)
            context.restoreGState()
        }
    }

    /// Éclats d'un bloc (au plus ~400), découpés dans l'image d'avant.
    static func debris(of rect: CGRect, in snapshot: ChartSnapshot) -> [Debris] {
        let cell = max(8, (rect.width * rect.height / 400).squareRoot())
        var random = SeededRandom(UInt64(rect.width * 131 + rect.height * 7))
        var pieces: [Debris] = []
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                let r = CGRect(x: x, y: y, width: min(cell, rect.maxX - x), height: min(cell, rect.maxY - y))
                if let image = snapshot.piece(r) {
                    pieces.append(Debris(image: image, rect: r,
                                         velocity: CGVector(dx: (random.next() - 0.5) * 140, dy: -random.next() * 110 - 10),
                                         spin: CGFloat((random.next() - 0.5) * 8), delay: random.next() * 0.25))
                }
                x += cell
            }
            y += cell
        }
        return pieces
    }
}

extension DiskNode {
    func isDescendant(of ancestor: DiskNode) -> Bool {
        var node = parent
        while let current = node {
            if current === ancestor { return true }
            node = current.parent
        }
        return false
    }
}

// MARK: - Pilotage depuis la vue du graphique

extension DiskChartView {
    /// Image et formes actuelles, pour animer un changement ; nil si la vue n'est pas à l'écran.
    func capture() -> ChartSnapshot? {
        guard window != nil, root != nil, bounds.width > 20, bounds.height > 20,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        ensureLayout()
        let overlayWasHidden = overlay.isHidden
        overlay.isHidden = true
        isSnapshotting = true
        cacheDisplay(in: bounds, to: rep)
        isSnapshotting = false
        overlay.isHidden = overlayWasHidden
        guard let image = rep.cgImage else { return nil }
        return ChartSnapshot(image: image, view: self)
    }

    /// Faut-il capturer l'état actuel avant ce changement ?
    func needsCapture(_ change: RootChange) -> Bool {
        switch change {
        case .none, .reveal, .baobab: false
        case .navigate: DiskEffects.on(.zoom) || DiskEffects.on(.unfold)
        case .live: DiskEffects.on(.liveScan)
        case .restyle: DiskEffects.on(.morph)
        case .trash: DiskEffects.on(.crumble)
        }
    }

    /// Change la racine affichée, avec l'animation qui convient à la cause du changement.
    /// `before` : état capturé avant une modification de l'arbre (corbeille).
    func show(_ node: DiskNode?, change: RootChange, before: ChartSnapshot? = nil) {
        let old = before ?? (needsCapture(change) && root != nil ? capture() : nil)
        root = node
        guard node != nil else { return }
        if case .baobab = change, DiskEffects.on(.baobab), let node {
            growBaobab(for: node)
            return
        }
        transition = makeTransition(change, from: old)
    }

    /// Change la représentation ou les couleurs en animant le passage.
    func restyle(_ apply: () -> Void) {
        let old = needsCapture(.restyle) && root != nil ? capture() : nil
        apply()
        transition = makeTransition(.restyle, from: old)
    }

    private func makeTransition(_ change: RootChange, from old: ChartSnapshot?) -> ChartTransition? {
        switch change {
        case .none: return nil
        case .reveal, .baobab: return revealTransition()
        case .navigate:
            guard let old, let new = capture(), let node = root else { return nil }
            if style.isRadial {
                if DiskEffects.on(.unfold) { return ChartTransition(.reveal(new, .unfold), duration: ChartTransition.revealDuration(new, .unfold)) }
                return DiskEffects.on(.zoom) ? ChartTransition(.fade(from: old, to: new), duration: 0.35) : nil
            }
            guard DiskEffects.on(.zoom) else { return nil }
            if let oldRoot = old.root, node.isDescendant(of: oldRoot), let focus = old.rect(near: node, stoppingAt: oldRoot) {
                return ChartTransition(.zoom(from: old, to: new, focus: focus, zoomIn: true), duration: 0.55)
            }
            if let oldRoot = old.root, oldRoot.isDescendant(of: node), let focus = new.rect(near: oldRoot, stoppingAt: node) {
                return ChartTransition(.zoom(from: old, to: new, focus: focus, zoomIn: false), duration: 0.55)
            }
            return ChartTransition(.fade(from: old, to: new), duration: 0.35)
        case .live:
            guard DiskEffects.on(.liveScan), let old, let new = capture() else { return nil }
            return ChartTransition(.pieces(from: old, to: new, debris: [], moveDelay: 0, moveDuration: 0.32), duration: 0.32)
        case .restyle:
            guard DiskEffects.on(.morph), let old, let new = capture() else { return nil }
            if old.style != new.style, !old.blocks.isEmpty, !new.blocks.isEmpty {
                return ChartTransition(.pieces(from: old, to: new, debris: [], moveDelay: 0, moveDuration: 0.7), duration: 0.7)
            }
            return ChartTransition(.fade(from: old, to: new), duration: old.style == new.style ? 0.25 : 0.35)
        case .trash(let removed):
            guard DiskEffects.on(.crumble), let old, let new = capture() else { return nil }
            guard !old.blocks.isEmpty, let rect = old.shapes.last(where: { $0.node === removed })?.rect, rect.width > 1 else {
                return ChartTransition(.fade(from: old, to: new), duration: 0.35)
            }
            return ChartTransition(.pieces(from: old, to: new, debris: ChartTransition.debris(of: rect, in: old), moveDelay: 0.3, moveDuration: 0.8),
                                   duration: 1.25, broken: [ObjectIdentifier(removed)])
        }
    }

    /// Fin d'une analyse : blocs qui grandissent (A) ou anneaux qui se déploient (D).
    func revealTransition() -> ChartTransition? {
        let mode: ChartTransition.Reveal
        if style.isRadial {
            if DiskEffects.on(.unfold) { mode = .unfold } else if DiskEffects.on(.growth) { mode = .fade } else { return nil }
        } else {
            guard DiskEffects.on(.growth) else { return nil }
            mode = style == .icicle ? .rows : style == .histogram ? .bars : .blocks
        }
        guard let snapshot = capture() else { return nil }
        return ChartTransition(.reveal(snapshot, mode), duration: ChartTransition.revealDuration(snapshot, mode))
    }

    /// Démarre ou arrête l'horloge d'affichage : elle ne tourne que pendant une animation.
    func transitionChanged() {
        overlay.isHidden = transition != nil
        needsDisplay = true
        if transition == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(animationTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc func animationTick(_ link: CADisplayLink) {
        if transition?.isFinished ?? true { transition = nil } else { needsDisplay = true }
    }

    // MARK: Effets superposés

    /// Le baobab pousse (H), puis le graphique se construit.
    func growBaobab(for node: DiskNode) {
        subviews.filter { $0 is BaobabOverlay }.forEach { $0.removeFromSuperview() }
        let overlay = BaobabOverlay(root: node)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.onFading = { [weak self] in
            guard let self, root === node else { return }
            transition = revealTransition()
        }
        addSubview(overlay)
        overlay.start()
    }

    /// Pluie de feuilles et compteur de l'espace libéré (I).
    func rainLeaves(freed: Int64) {
        guard DiskEffects.on(.leaves) else { return }
        subviews.filter { $0 is LeavesOverlay }.forEach { $0.removeFromSuperview() }
        let overlay = LeavesOverlay(freed: freed)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        overlay.start()
    }
}
