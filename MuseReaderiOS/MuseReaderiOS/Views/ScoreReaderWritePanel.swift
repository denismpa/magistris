#if !os(Android)
import Foundation
import SwiftUI

struct ScoreReaderWritePanel: View {
    let controller: ScoreReaderWriteController
    let isEditingBusy: Bool
    let convertAction: () -> Void
    @State private var showsDrawingGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Write", systemImage: "pencil.tip")
                    .font(.headline)
                Button("Drawing guide", systemImage: "questionmark.circle") {
                    showsDrawingGuide = true
                }
                .labelStyle(.iconOnly)
                .popover(isPresented: $showsDrawingGuide) {
                    drawingGuide
                }
                Spacer(minLength: 12)
                Button("Cancel") { controller.cancel() }
                    .disabled(controller.isConverting)
            }

            if let target = controller.target {
                Text("Bar \(target.measureIndex + 1) · Voice \(target.voice + 1) · \(target.timeSignatureNumerator)/\(target.timeSignatureDenominator)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.isPreparing {
                ProgressView("Preparing the selected bar…")
            } else {
                Text("Draw whole, half, quarter or flagged eighth notes and rests with Apple Pencil. Ink is temporary until you tap Convert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let image = controller.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 112)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Engraved preview of the handwritten bar")
                }

                if let message = controller.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if controller.isReviewing {
                    ProgressView("Recognizing handwriting…")
                        .font(.caption)
                } else if let recognition = controller.recognition {
                    if !recognition.issues.isEmpty {
                        Text(recognition.issues.prefix(2).map(\.message).joined(separator: " "))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(rhythmSummary(recognition))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Write inside the highlighted bar. Fingers scroll and zoom the page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        inkControls
                        Spacer(minLength: 8)
                        reviewControls
                    }
                    VStack(alignment: .trailing, spacing: 8) {
                        inkControls
                        reviewControls
                    }
                }
                .buttonStyle(.bordered)
                .font(.callout.weight(.medium))
            }
        }
        .padding(16)
        .frame(maxWidth: 900)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityIdentifier("score.write.panel")
    }

    private var inkControls: some View {
        HStack(spacing: 10) {
            Button("Undo Ink", systemImage: "arrow.uturn.backward") { controller.undoInk() }
                .disabled(controller.strokes.isEmpty || !controller.canCapture)
            Button("Clear") { controller.clearInk() }
                .disabled(controller.strokes.isEmpty || !controller.canCapture)
        }
        .fixedSize()
    }

    private var drawingGuide: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Drawing guide").font(.headline)
                Text("Whole note: an open oval. Half note: an open oval with one stem. Quarter note: a filled oval or short diagonal head with one stem. Eighth note: add one curved flag.")
                Text("Whole rest: a rectangular block hanging from the second line. Half rest: a block sitting on the middle line. Quarter rest: a zigzag with a lower hook. Eighth rest: a small loop followed by a slanted downward tail in one stroke.")
                Text("Draw notes from left to right. You can draw heads and stems separately. Add one or two dots to the right for dotted durations.")
                Text("Review the engraved preview before converting. Chords, beams, accidentals, ties, tuplets and percussion handwriting need the existing editor in this prototype.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(20)
        }
        .frame(width: 340, height: 420)
    }

    private var reviewControls: some View {
        HStack(spacing: 10) {
            Button("Review") { controller.review() }
                .disabled(controller.strokes.isEmpty || !controller.activePoints.isEmpty
                          || !controller.canCapture || controller.isReviewing)
            Button("Convert", action: convertAction)
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canConvert || isEditingBusy)
                .accessibilityIdentifier("score.write.convert")
        }
        .fixedSize()
    }

    private func rhythmSummary(_ recognition: MusicInkRecognition) -> String {
        let written = String(format: "%g", Double(recognition.recognizedDurationTicks) / 480)
        let capacity = String(format: "%g", Double(recognition.measureDurationTicks) / 480)
        let remaining = recognition.measureDurationTicks - recognition.recognizedDurationTicks
        if remaining > 0 {
            return "\(recognition.events.count) symbols · \(written) of \(capacity) quarter-note beats. The remaining time becomes rests."
        }
        return "\(recognition.events.count) symbols · \(written) of \(capacity) quarter-note beats."
    }
}
#endif
