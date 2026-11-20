import AppKit
import QuartzCore

/// The rings of the to-dos in progress, turning. They are layers over the text, so the turning runs in
/// the render server: nothing is redrawn for a frame, and typing does not disturb it.
final class TaskSpinnerOverlay: NSView {
    struct Ring: Equatable {
        /// The square the ring fills, in this view's coordinates.
        var frame: NSRect
        var opacity: Float = 1
    }

    /// Seconds for one turn.
    static let period: CFTimeInterval = 1.4
    private static let animationKey = "turn"

    private let color: NSColor
    private(set) var rings: [Ring] = []
    private var ringLayers: [CAShapeLayer] = []
    /// All rings turn together, whenever they appeared.
    private let epoch = CACurrentMediaTime()

    /// Off while the note cannot be seen, and with 「視差効果を減らす」: the rings stand still.
    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            ringLayers.forEach(updateAnimation)
        }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // Clicks go to the text under the rings.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ rings: [Ring]) {
        guard rings != self.rings, let host = layer else { return }
        self.rings = rings
        CATransaction.begin()
        CATransaction.setDisableActions(true) // the rings follow the text at once, without gliding
        while ringLayers.count > rings.count { ringLayers.removeLast().removeFromSuperlayer() }
        while ringLayers.count < rings.count {
            let ring = CAShapeLayer()
            ring.fillColor = nil
            ring.lineCap = .butt
            ring.strokeColor = color.cgColor
            host.addSublayer(ring)
            ringLayers.append(ring)
            updateAnimation(ring)
        }
        for (ring, layer) in zip(rings, ringLayers) {
            // The turning is an animation of the presentation only, so the frame can be set as usual.
            layer.frame = ring.frame
            layer.path = TaskSignalIcon.ringPath(in: layer.bounds)
            layer.lineWidth = TaskSignalIcon.ringLineWidth(in: layer.bounds)
            layer.opacity = ring.opacity
        }
        CATransaction.commit()
    }

    private func updateAnimation(_ layer: CAShapeLayer) {
        layer.removeAnimation(forKey: Self.animationKey)
        guard isAnimating else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi // the view is flipped (y points down): a growing angle turns clockwise
        turn.duration = Self.period
        turn.repeatCount = .infinity
        turn.timeOffset = (CACurrentMediaTime() - epoch).truncatingRemainder(dividingBy: Self.period)
        layer.add(turn, forKey: Self.animationKey)
    }

    /// Whether the rings are turning (for tests).
    var isTurning: Bool { ringLayers.contains { $0.animation(forKey: Self.animationKey) != nil } }
}
