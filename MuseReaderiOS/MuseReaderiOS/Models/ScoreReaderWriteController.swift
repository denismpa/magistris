#if !os(Android)
import Foundation
import Observation
import SwiftUI
import UIKit

private struct ScoreReaderWriteControllerKey: EnvironmentKey {
    static let defaultValue: ScoreReaderWriteController? = nil
}

private struct ScoreReaderWritePageIndexKey: EnvironmentKey {
    static let defaultValue = -1
}

extension EnvironmentValues {
    var scoreReaderWriteController: ScoreReaderWriteController? {
        get { self[ScoreReaderWriteControllerKey.self] }
        set { self[ScoreReaderWriteControllerKey.self] = newValue }
    }

    var scoreReaderWritePageIndex: Int {
        get { self[ScoreReaderWritePageIndexKey.self] }
        set { self[ScoreReaderWritePageIndexKey.self] = newValue }
    }
}

@MainActor
@Observable
final class ScoreReaderWriteController {
    private(set) var isActive = false
    private(set) var isPreparing = false
    private(set) var isReviewing = false
    private(set) var isConverting = false
    private(set) var target: ScoreHandwritingTarget?
    private(set) var strokes: [MusicInkStroke] = []
    private(set) var activePoints: [MusicInkPoint] = []
    private(set) var recognition: MusicInkRecognition?
    private(set) var previewImage: UIImage?
    private(set) var message: String?
    @ObservationIgnored private var session: LiveScoreRenderSession?
    @ObservationIgnored private var reviewTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var proposedEvents: [ScoreHandwritingEvent] = []
    @ObservationIgnored private var pageAspectRatio = 1.0

    static let maximumStrokes = 64
    static let maximumPoints = 16_384

    var remainingPointBudget: Int {
        Self.maximumPoints - strokes.reduce(0) { $0 + $1.points.count }
    }

    var canCapture: Bool {
        isActive && target != nil && !isPreparing && !isConverting
    }

    var canConvert: Bool {
        canCapture && activePoints.isEmpty && !isReviewing
            && recognition?.canConvert == true && previewImage != nil && !proposedEvents.isEmpty
    }

    var writingRegion: MusicWritingRegion? {
        guard let target else { return nil }
        return MusicWritingRegion(
            left: target.inputStartNormalizedX,
            right: target.inputEndNormalizedX,
            top: max(0, min(target.measureRect.y, target.staffTopNormalizedY - target.staffHalfStepNormalizedY * 10)),
            bottom: min(1, max(target.measureRect.y + target.measureRect.height,
                               target.staffTopNormalizedY + target.staffHalfStepNormalizedY * 18)),
            staffTopY: target.staffTopNormalizedY,
            staffHalfStepY: target.staffHalfStepNormalizedY,
            measureDurationTicks: target.durationTicks
        )
    }

    func begin(in reader: ScoreReaderState) {
        guard !isActive, reader.isEditingMode, !reader.isEditingActionInFlight,
              reader.session.liveRenderSession != nil else { return }
        reset()
        isActive = true
        isPreparing = true
        let request = revision
        reader.clearNoteEntryPreview()
        reader.performEditingAction(mutatesScore: false) { [weak self, weak reader] session in
            do {
                let state = try await session.setNoteInputEnabled(false)
                let target = try await session.handwritingTargetForSelection()
                guard let self, self.revision == request, self.isActive else { return state }
                guard reader?.selectedPageIndex == target.pageIndex else {
                    self.reset()
                    self.message = "Return to the selected bar, then choose Write again."
                    return state
                }
                guard let size = reader?.page(at: target.pageIndex)?.displaySize,
                      size.width > 0, size.height > 0 else {
                    self.reset()
                    self.message = "Wait for the selected page to finish loading, then choose Write again."
                    return state
                }
                self.session = session
                self.pageAspectRatio = Double(size.width / size.height)
                self.target = target
                self.isPreparing = false
                self.message = nil
                reader?.revealActiveSelection(in: state)
                return state
            } catch {
                if let self, self.revision == request {
                    self.reset()
                    self.message = error.localizedDescription
                }
                throw error
            }
        }
    }

    func canBeginStroke(at point: CGPoint, pageIndex: Int) -> Bool {
        guard canCapture, target?.pageIndex == pageIndex, let region = writingRegion else { return false }
        guard strokes.count < Self.maximumStrokes, remainingPointBudget > 0 else {
            rejectStroke("This bar has too much ink. Undo ink or clear it before drawing more.")
            return false
        }
        return Double(point.x) >= region.left && Double(point.x) <= region.right
            && Double(point.y) >= region.top && Double(point.y) <= region.bottom
    }

    func updateStroke(_ points: [MusicInkPoint]) {
        guard canCapture else { return }
        invalidateReview()
        recognition = nil
        activePoints = points
    }

    func finishStroke(_ points: [MusicInkPoint]) {
        guard canCapture, !points.isEmpty else { return }
        guard points.count <= remainingPointBudget, strokes.count < Self.maximumStrokes else {
            rejectStroke("This bar has too much ink. Undo ink or clear it before drawing more.")
            return
        }
        activePoints = []
        strokes.append(MusicInkStroke(points: points))
        review(after: .milliseconds(450))
    }

    func rejectStroke(_ reason: String) {
        invalidateReview()
        activePoints = []
        recognition = nil
        message = reason
    }

    func cancelActiveStroke() {
        guard !activePoints.isEmpty else { return }
        activePoints = []
        review(after: .milliseconds(150))
    }

    func undoInk() {
        guard canCapture, !strokes.isEmpty else { return }
        activePoints = []
        strokes.removeLast()
        review(after: .zero)
    }

    func clearInk() {
        guard canCapture else { return }
        invalidateReview()
        strokes.removeAll()
        activePoints.removeAll()
        recognition = nil
        message = nil
    }

    func review(after delay: Duration = .zero) {
        invalidateReview()
        guard canCapture, activePoints.isEmpty, !strokes.isEmpty,
              let target, let region = writingRegion, let session else {
            recognition = nil
            return
        }
        // Recognition needs the same physical scale on both axes. Normalized
        // page x and y have different lengths on a portrait page.
        let capturedStrokes = strokes.map { stroke in
            MusicInkStroke(id: stroke.id, points: stroke.points.map {
                MusicInkPoint(x: $0.x * pageAspectRatio, y: $0.y, time: $0.time)
            })
        }
        let recognitionRegion = MusicWritingRegion(
            left: region.left * pageAspectRatio, right: region.right * pageAspectRatio,
            top: region.top, bottom: region.bottom, staffTopY: region.staffTopY,
            staffHalfStepY: region.staffHalfStepY, measureDurationTicks: region.measureDurationTicks
        )
        let request = revision
        isReviewing = true
        reviewTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                let result = await Task.detached(priority: .userInitiated) {
                    MusicInkRecognizer.recognize(strokes: capturedStrokes, in: recognitionRegion)
                }.value
                guard let self, !Task.isCancelled, self.revision == request, self.canCapture else { return }
                self.recognition = result
                guard result.canConvert else {
                    self.isReviewing = false
                    return
                }
                let events = result.events.map { event in
                    ScoreHandwritingEvent(
                        durationCode: event.durationCode, dots: event.dots,
                        staffLine: event.staffStep ?? 0, rest: event.isRest
                    )
                }
                let preview = try await session.previewHandwriting(events, target: target)
                guard !Task.isCancelled, self.revision == request, self.canCapture else { return }
                guard let image = UIImage(data: preview.imageData) else {
                    self.message = "The engraved preview could not be displayed. Review the drawing again."
                    self.isReviewing = false
                    return
                }
                self.proposedEvents = events
                self.previewImage = image
                self.isReviewing = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.revision == request else { return }
                self.message = error.localizedDescription
                self.isReviewing = false
            }
        }
    }

    func convert(in reader: ScoreReaderState) {
        guard canConvert, !reader.isEditingActionInFlight, let target else { return }
        let events = proposedEvents
        let request = revision
        isConverting = true
        reader.performEditingAction(mutatesScore: true, revealActiveNotation: true) { [weak self] session in
            do {
                let state = try await session.commitHandwriting(events, target: target)
                if let self, self.revision == request {
                    self.reset()
                    self.message = "Handwriting converted. Use Undo to restore the empty bar."
                }
                return state
            } catch {
                if let self, self.revision == request {
                    self.isConverting = false
                    self.invalidateReview()
                    self.message = error.localizedDescription
                }
                throw error
            }
        }
    }

    func cancel(message: String? = nil) {
        guard !isConverting else { return }
        reset()
        self.message = message
    }

    private func invalidateReview() {
        revision += 1
        reviewTask?.cancel()
        reviewTask = nil
        isReviewing = false
        previewImage = nil
        proposedEvents.removeAll()
        message = nil
    }

    private func reset() {
        invalidateReview()
        isActive = false
        isPreparing = false
        isConverting = false
        target = nil
        strokes.removeAll()
        activePoints.removeAll()
        recognition = nil
        session = nil
    }

}
#endif
