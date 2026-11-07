#if !os(Android)
import AVFoundation
import UIKit

struct ScoreWriteTouchSample {
    let point: CGPoint
    let time: TimeInterval
}

final class ScoreReaderWriteGestureRecognizer: UIGestureRecognizer {
    private(set) var samples: [ScoreWriteTouchSample] = []
    var acceptsStart: ((CGPoint) -> Bool)?
    var maximumPoints = 2_048
    private(set) var exceededPointLimit = false
    private weak var trackedTouch: UITouch?

    override func reset() {
        super.reset()
        trackedTouch = nil
        exceededPointLimit = false
        samples.removeAll(keepingCapacity: true)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, let touch = touches.first(where: { $0.type == .pencil }),
              let view, acceptsStart?(touch.preciseLocation(in: view)) == true else {
            state = .failed
            return
        }
        trackedTouch = touch
        append(touch, event: event, in: view)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch), let view else { return }
        append(touch, event: event, in: view)
        state = exceededPointLimit ? .cancelled : .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch), let view else { return }
        append(touch, event: event, in: view)
        state = exceededPointLimit ? .cancelled : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    private func append(_ touch: UITouch, event: UIEvent, in view: UIView) {
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
            // Predicted samples belong to display only. Recognition receives
            // the actual path, including the final delivered point.
            if samples.last?.time == sample.timestamp { continue }
            guard samples.count < maximumPoints else {
                exceededPointLimit = true
                return
            }
            samples.append(ScoreWriteTouchSample(point: sample.preciseLocation(in: view), time: sample.timestamp))
        }
    }
}

final class ScoreReaderWriteInkView: UIView {
    var imageSize: CGSize = .zero
    var controller: ScoreReaderWriteController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let controller, let target = controller.target, let region = controller.writingRegion, controller.isActive,
              imageSize.width > 0, imageSize.height > 0,
              let context = UIGraphicsGetCurrentContext() else { return }
        let imageRect = AVMakeRect(aspectRatio: imageSize, insideRect: bounds)
        let targetRect = CGRect(
            x: imageRect.minX + CGFloat(region.left) * imageRect.width,
            y: imageRect.minY + CGFloat(region.top) * imageRect.height,
            width: CGFloat(region.right - region.left) * imageRect.width,
            height: CGFloat(region.bottom - region.top) * imageRect.height
        )
        context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.035).cgColor)
        context.fill(targetRect)
        context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.65).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.stroke(targetRect)
        context.setLineDash(phase: 0, lengths: [])
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setFillColor(UIColor.systemBlue.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(max(CGFloat(target.staffHalfStepNormalizedY) * imageRect.height * 0.32, 1))
        for stroke in controller.strokes {
            draw(stroke.points, in: imageRect, context: context)
        }
        draw(controller.activePoints, in: imageRect, context: context)
    }

    private func draw(_ points: [MusicInkPoint], in imageRect: CGRect, context: CGContext) {
        guard let first = points.first else { return }
        let start = CGPoint(x: imageRect.minX + CGFloat(first.x) * imageRect.width,
                            y: imageRect.minY + CGFloat(first.y) * imageRect.height)
        if points.count == 1 {
            context.fillEllipse(in: CGRect(x: start.x - 1, y: start.y - 1, width: 2, height: 2))
            return
        }
        context.beginPath()
        context.move(to: start)
        for point in points.dropFirst() {
            context.addLine(to: CGPoint(x: imageRect.minX + CGFloat(point.x) * imageRect.width,
                                       y: imageRect.minY + CGFloat(point.y) * imageRect.height))
        }
        context.strokePath()
    }
}
#endif
