// SPDX-License-Identifier: MIT
// Original authored trajectory fixtures. These verify behavior, not accuracy
// on unseen writers. Compile together with MusicInkRecognizer.swift.
import Foundation

@main
struct MusicInkRecognizerChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let region = MusicWritingRegion(left: 0, right: 600, top: 0, bottom: 240,
                                           staffTopY: 80, staffHalfStepY: 10, measureDurationTicks: 1920)

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func stroke(_ points: [(Double, Double)]) -> MusicInkStroke {
        .init(points: points.enumerated().map { .init(x: $0.element.0, y: $0.element.1, time: Double($0.offset) * 0.012) })
    }

    static func oval(x: Double, y: Double, width: Double = 24, height: Double = 14,
                     tilt: Double = -0.18, samples: Int = 32) -> MusicInkStroke {
        let points = (0...samples).map { index -> (Double, Double) in
            let angle = Double(index) / Double(samples) * 2 * .pi
            let dy = sin(angle) * height / 2
            return (x + cos(angle) * width / 2 + tilt * dy, y + dy)
        }
        return stroke(points)
    }

    static func note(x: Double, y: Double, open: Bool = false, eighth: Bool = false,
                     down: Bool = false, width: Double = 24, height: Double = 14) -> [MusicInkStroke] {
        var parts = [oval(x: x, y: y, width: width, height: height)]
        if !open { parts.append(stroke([(x - width * 0.32, y + 3), (x, y), (x + width * 0.3, y - 3)])) }
        let edge = x + (down ? -width / 2 : width / 2)
        let direction = down ? 1.0 : -1.0
        let tip = y + direction * 54
        parts.append(stroke([(edge, y), (edge + 1, y + direction * 27), (edge, tip)]))
        if eighth {
            parts.append(stroke([(edge, tip), (edge + 11, tip - direction * 10),
                                 (edge + 14, tip - direction * 22), (edge + 7, tip - direction * 34)]))
        }
        return parts
    }

    static func describe(_ result: MusicInkRecognition) -> String {
        result.issues.map(\.message).joined(separator: " ")
    }

    static func main() throws {
        var passed = 0
        func check(_ name: String, _ body: () throws -> Void) throws {
            try body()
            passed += 1
            print("PASS \(name)")
        }

        try check("separate oval and filling strokes form one quarter note") {
            let ink = note(x: 80, y: 120)
            let result = MusicInkRecognizer.recognize(strokes: ink, in: region)
            try expect(result.canConvert, describe(result))
            try expect(result.events.count == 1 && result.events[0].durationCode == 4, "Expected one quarter note")
            try expect(result.events[0].staffStep == 4, "Expected the middle staff line")
            try expect(Set(result.events[0].sourceStrokeIDs) == Set(ink.map(\.id)), "All head/fill/stem strokes must belong to the note")
            try expect(result.recognizedDurationTicks == 480 && result.remainingDurationTicks == 1440, "Trailing rest tally is wrong")
        }

        try check("open heads distinguish whole and half notes") {
            let whole = MusicInkRecognizer.recognize(strokes: [oval(x: 90, y: 100, width: 30, height: 16)], in: region)
            try expect(whole.canConvert && whole.events.first?.durationCode == 1, describe(whole))
            let half = MusicInkRecognizer.recognize(strokes: note(x: 90, y: 110, open: true), in: region)
            try expect(half.canConvert && half.events.first?.durationCode == 2, describe(half))
        }

        try check("short diagonal head and separate stem") {
            let ink = [stroke([(72, 126), (88, 114)]), stroke([(88, 120), (87, 65)])]
            let result = MusicInkRecognizer.recognize(strokes: ink, in: region)
            try expect(result.canConvert && result.events.first?.durationCode == 4, describe(result))
        }

        try check("one continuous open loop and stem") {
            var joined = oval(x: 90, y: 120).points
            joined.append(contentsOf: stroke([(102, 120), (102, 65)]).points)
            let result = MusicInkRecognizer.recognize(strokes: [.init(points: joined)], in: region)
            try expect(result.canConvert && result.events.first?.durationCode == 2, describe(result))
        }

        try check("continuous filled head and stem with a looser oval") {
            var joined = oval(x: 90, y: 120, width: 27, height: 15, tilt: -0.3, samples: 19).points
            joined.append(contentsOf: stroke([(82, 123), (97, 116), (103, 120), (103, 65)]).points)
            let result = MusicInkRecognizer.recognize(strokes: [.init(points: joined)], in: region)
            try expect(result.canConvert && result.events.first?.durationCode == 4, describe(result))
        }

        try check("curved flags with upward and downward stems") {
            for down in [false, true] {
                let result = MusicInkRecognizer.recognize(strokes: note(x: 100, y: 110, eighth: true, down: down), in: region)
                try expect(result.canConvert && result.events.first?.durationCode == 8, describe(result))
            }
        }

        try check("dotted and double dotted notes preserve exact rhythm") {
            for dots in 1...2 {
                var ink = note(x: 100, y: 120)
                ink.append(stroke([(125, 120), (126, 120)]))
                if dots == 2 { ink.append(stroke([(134, 120), (135, 120)])) }
                let result = MusicInkRecognizer.recognize(strokes: ink, in: region)
                try expect(result.canConvert && result.events.first?.dots == dots, describe(result))
                try expect(result.recognizedDurationTicks == (dots == 1 ? 720 : 840), "Dotted quarter tally is wrong")
            }
        }

        try check("notes follow horizontal order despite stroke entry order") {
            let ink = note(x: 230, y: 130, open: true, down: true)
                + note(x: 70, y: 100, width: 21, height: 12)
                + note(x: 155, y: 110, width: 27, height: 16)
            let result = MusicInkRecognizer.recognize(strokes: Array(ink.reversed()), in: region)
            try expect(result.canConvert && result.events.map(\.durationCode) == [4, 4, 2], describe(result))
            try expect(result.events.map(\.staffStep) == [2, 3, 5], "Staff positions are wrong")
            try expect(result.recognizedDurationTicks == 1920 && result.remainingDurationTicks == 0, "Full bar tally is wrong")
        }

        try check("whole and half block rests use their staff lines") {
            let whole = stroke([(80, 100), (104, 100), (104, 108), (80, 108), (80, 100)])
            let half = stroke([(80, 112), (104, 112), (104, 120), (80, 120), (80, 112)])
            for (ink, code) in [(whole, 1), (half, 2)] {
                let result = MusicInkRecognizer.recognize(strokes: [ink], in: region)
                try expect(result.canConvert && result.events.first?.isRest == true && result.events.first?.durationCode == code, describe(result))
            }
        }

        try check("quarter rest zigzag and eighth rest loop with slanted tail") {
            let quarter = stroke([(99, 92), (90, 106), (103, 118), (89, 130), (99, 145)])
            var hook = oval(x: 200, y: 105, width: 8, height: 8, tilt: 0).points
            hook.append(contentsOf: stroke([(204, 105), (210, 101), (193, 140)]).points)
            let result = MusicInkRecognizer.recognize(strokes: [quarter, .init(points: hook)], in: region)
            try expect(result.canConvert && result.events.map(\.durationCode) == [4, 8], describe(result))
            try expect(result.events.allSatisfy(\.isRest), "Expected rests")
        }

        try check("single line notes and block rest") {
            var single = region
            single.lineCount = 1
            let result = MusicInkRecognizer.recognize(strokes: note(x: 80, y: 80), in: single)
            try expect(result.canConvert && result.events.first?.staffStep == 0, describe(result))
            let half = stroke([(150, 72), (174, 72), (174, 80), (150, 80), (150, 72)])
            let rest = MusicInkRecognizer.recognize(strokes: [half], in: single)
            try expect(rest.canConvert && rest.events.first?.isRest == true && rest.events.first?.durationCode == 2, describe(rest))
        }

        try check("unknown strokes remain uncertain alongside recognized notes") {
            let unknown = [stroke([(210, 80), (245, 125)]), stroke([(210, 125), (245, 80)])]
            let result = MusicInkRecognizer.recognize(strokes: note(x: 80, y: 120) + unknown, in: region)
            try expect(!result.canConvert && result.events.count == 1, "Unrecognized ink must prevent conversion")
            try expect(result.issues.contains { $0.kind == .unsupportedSymbol && Set($0.sourceStrokeIDs) == Set(unknown.map(\.id)) }, "Unknown stroke identity was lost")
        }

        try check("closed scribbles misplaced blocks and staccato stay unresolved") {
            let scribble = stroke([(220, 100), (230, 110), (220, 130), (210, 145), (220, 155),
                                   (230, 145), (220, 125), (210, 110), (220, 100)])
            let unknown = MusicInkRecognizer.recognize(strokes: [scribble], in: region)
            try expect(!unknown.canConvert, "A closed scribble was misread as a quarter rest")
            let misplaced = stroke([(80, 132), (104, 132), (104, 140), (80, 140), (80, 132)])
            let block = MusicInkRecognizer.recognize(strokes: [misplaced], in: region)
            try expect(!block.canConvert && block.issues.contains { $0.kind == .ambiguousPlacement }, "A displaced rest was misread as a whole note")
            let staccato = MusicInkRecognizer.recognize(strokes: note(x: 90, y: 120) + [stroke([(90, 100)])], in: region)
            try expect(!staccato.canConvert && staccato.events.first?.dots == 0, "Staccato was misread as an augmentation dot")
        }

        try check("ambiguous pitch and missing stem need correction") {
            let between = MusicInkRecognizer.recognize(strokes: note(x: 80, y: 125), in: region)
            try expect(!between.canConvert && between.issues.contains { $0.kind == .ambiguousPlacement && $0.candidates.count == 2 }, "Midway pitch needs alternatives")
            let bare = MusicInkRecognizer.recognize(strokes: [stroke([(72, 126), (88, 114)])], in: region)
            try expect(!bare.canConvert && bare.issues.contains { $0.kind == .ambiguousSymbol }, "A bare filled head needs a stem")
        }

        try check("overlapping heads and open heads with flags abstain") {
            let chord = MusicInkRecognizer.recognize(strokes: note(x: 100, y: 100) + note(x: 100, y: 140, down: true), in: region)
            try expect(!chord.canConvert, "Unsupported chord must require correction")
            let inconsistent = MusicInkRecognizer.recognize(strokes: note(x: 100, y: 100, open: true, eighth: true), in: region)
            try expect(!inconsistent.canConvert, "An open flagged head is ambiguous")
        }

        try check("out of bounds and invalid input fail safely") {
            let outside = stroke([(-1, 80), (20, 100)])
            let out = MusicInkRecognizer.recognize(strokes: [outside], in: region)
            try expect(!out.canConvert && out.issues.first?.kind == .outOfBounds, "Outside ink must be reported")
            let invalid = MusicInkRecognizer.recognize(strokes: [stroke([(.nan, 80)])], in: region)
            try expect(!invalid.canConvert && invalid.issues.first?.kind == .invalidInput, "Invalid coordinates must be rejected")
            var badRegion = region
            badRegion.staffHalfStepY = 0
            try expect(!MusicInkRecognizer.recognize(strokes: note(x: 80, y: 100), in: badRegion).canConvert, "Invalid staff geometry accepted")
            try expect(!MusicInkRecognizer.recognize(strokes: [], in: region).canConvert, "Empty input accepted")
        }

        try check("overflow is measured rather than clipped or shortened") {
            let result = MusicInkRecognizer.recognize(strokes: note(x: 80, y: 120, open: true)
                + note(x: 180, y: 120, open: true) + note(x: 280, y: 120), in: region)
            try expect(!result.canConvert && result.recognizedDurationTicks == 2400, "Rhythm overflow was hidden")
            try expect(result.issues.contains { $0.kind == .rhythmOverflow }, "Overflow needs an explanation")
        }

        try check("translation scaling and page coordinates preserve recognition") {
            let original = note(x: 90, y: 110, eighth: true) + note(x: 190, y: 140, open: true, down: true)
            let reference = MusicInkRecognizer.recognize(strokes: original, in: region)
            for scale in [0.0012, 0.5, 2.7] {
                let tx = 0.17
                let ty = 0.08
                let transformed = original.map { ink in
                    MusicInkStroke(id: ink.id, points: ink.points.map { .init(x: tx + $0.x * scale, y: ty + $0.y * scale, time: $0.time) })
                }
                let area = MusicWritingRegion(left: tx, right: tx + 600 * scale, top: ty, bottom: ty + 240 * scale,
                                              staffTopY: ty + 80 * scale, staffHalfStepY: 10 * scale, measureDurationTicks: 1920)
                let result = MusicInkRecognizer.recognize(strokes: transformed, in: area)
                try expect(result.canConvert, describe(result))
                try expect(result.events.map(\.durationCode) == reference.events.map(\.durationCode)
                    && result.events.map(\.staffStep) == reference.events.map(\.staffStep), "Coordinate transform changed recognition")
            }
        }

        print("\(passed) authored trajectory checks passed. Writer accuracy has not been measured.")
    }
}
