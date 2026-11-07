// SPDX-License-Identifier: MIT

import Foundation

public nonisolated struct MusicInkPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var time: Double

    public init(x: Double, y: Double, time: Double = 0) {
        self.x = x
        self.y = y
        self.time = time
    }
}

public nonisolated struct MusicInkStroke: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var points: [MusicInkPoint]

    public init(id: UUID = UUID(), points: [MusicInkPoint]) {
        self.id = id
        self.points = points
    }
}

/// Coordinates share an isotropic space with the ink: one x unit and one y unit
/// represent the same physical distance. Staff steps increase downward.
public nonisolated struct MusicWritingRegion: Equatable, Sendable {
    public var left: Double
    public var right: Double
    public var top: Double
    public var bottom: Double
    public var staffTopY: Double
    public var staffHalfStepY: Double
    public var lineCount: Int
    public var measureDurationTicks: Int
    public var quarterNoteTicks: Int

    public init(left: Double, right: Double, top: Double, bottom: Double,
                staffTopY: Double, staffHalfStepY: Double, lineCount: Int = 5,
                measureDurationTicks: Int, quarterNoteTicks: Int = 480) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
        self.staffTopY = staffTopY
        self.staffHalfStepY = staffHalfStepY
        self.lineCount = lineCount
        self.measureDurationTicks = measureDurationTicks
        self.quarterNoteTicks = quarterNoteTicks
    }
}

public nonisolated struct MusicRecognizedEvent: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sourceStrokeIDs: [UUID]
    public var centerX: Double
    public var staffStep: Int?
    public var durationCode: Int
    public var dots: Int
    public var isRest: Bool

    public init(id: UUID, sourceStrokeIDs: [UUID], centerX: Double, staffStep: Int?,
                durationCode: Int, dots: Int = 0, isRest: Bool) {
        self.id = id
        self.sourceStrokeIDs = sourceStrokeIDs
        self.centerX = centerX
        self.staffStep = staffStep
        self.durationCode = durationCode
        self.dots = dots
        self.isRest = isRest
    }

    public func durationTicks(quarterNoteTicks: Int = 480) -> Int {
        guard [1, 2, 4, 8].contains(durationCode), (0...2).contains(dots),
              quarterNoteTicks > 0, quarterNoteTicks <= Int.max / 16 else { return 0 }
        let base = quarterNoteTicks * 4 / durationCode
        return base + (dots > 0 ? base / 2 : 0) + (dots > 1 ? base / 4 : 0)
    }
}

public nonisolated struct MusicInkIssue: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case invalidInput, emptyInput, outOfBounds, ambiguousSymbol, ambiguousPlacement
        case unsupportedSymbol, rhythmOverflow
    }

    public var kind: Kind
    public var message: String
    public var sourceStrokeIDs: [UUID]
    public var candidates: [String]

    public init(kind: Kind, message: String, sourceStrokeIDs: [UUID] = [], candidates: [String] = []) {
        self.kind = kind
        self.message = message
        self.sourceStrokeIDs = sourceStrokeIDs
        self.candidates = candidates
    }
}

public nonisolated struct MusicInkRecognition: Equatable, Sendable {
    public var events: [MusicRecognizedEvent]
    public var issues: [MusicInkIssue]
    public var recognizedDurationTicks: Int
    public var measureDurationTicks: Int

    public init(events: [MusicRecognizedEvent], issues: [MusicInkIssue],
                recognizedDurationTicks: Int, measureDurationTicks: Int) {
        self.events = events
        self.issues = issues
        self.recognizedDurationTicks = recognizedDurationTicks
        self.measureDurationTicks = measureDurationTicks
    }

    public var remainingDurationTicks: Int { max(0, measureDurationTicks - recognizedDurationTicks) }
    public var canConvert: Bool {
        !events.isEmpty && issues.isEmpty && recognizedDurationTicks <= measureDurationTicks
    }
}

/// A deliberately limited geometric prototype. Thresholds describe supported
/// shapes, not calibrated probabilities. The caller previews every proposal.
public nonisolated enum MusicInkRecognizer {
    public static func recognize(strokes: [MusicInkStroke], in region: MusicWritingRegion) -> MusicInkRecognition {
        var result = MusicInkRecognition(events: [], issues: [], recognizedDurationTicks: 0,
                                        measureDurationTicks: max(0, region.measureDurationTicks))
        guard valid(region), strokes.count <= 128, Set(strokes.map(\.id)).count == strokes.count else {
            result.issues = [.init(kind: .invalidInput, message: "The writing area or stroke identities are invalid.")]
            return result
        }
        guard !strokes.isEmpty else {
            result.issues = [.init(kind: .emptyInput, message: "Write a note or rest in the measure.")]
            return result
        }

        let spacing = region.staffHalfStepY * 2
        var parts: [InkPart] = []
        for stroke in strokes {
            guard !stroke.points.isEmpty, stroke.points.count <= 16_384,
                  stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.time.isFinite }) else {
                result.issues.append(.init(kind: .invalidInput, message: "A stroke contains invalid points.", sourceStrokeIDs: [stroke.id]))
                continue
            }
            guard stroke.points.allSatisfy({ $0.x >= region.left && $0.x <= region.right
                && $0.y >= region.top && $0.y <= region.bottom }) else {
                result.issues.append(.init(kind: .outOfBounds, message: "Keep this stroke inside the selected measure's writing area.", sourceStrokeIDs: [stroke.id]))
                continue
            }
            let normalized = stroke.points.map {
                InkPoint(x: ($0.x - region.left) / spacing, y: ($0.y - region.staffTopY) / spacing)
            }
            guard normalized.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 100_000 && abs($0.y) < 100_000 }) else {
                result.issues.append(.init(kind: .invalidInput, message: "The writing scale is invalid.", sourceStrokeIDs: [stroke.id]))
                continue
            }
            let points = resample(normalized)
            for piece in splitHeadAndStem(points) {
                parts.append(InkPart(index: parts.count, source: stroke.id, points: piece))
            }
        }

        var used = Set<Int>()
        var symbols: [InkSymbol] = []
        // Rests have their own structure and staff placement. Recognize them
        // before a small rest bulb could be mistaken for a notehead or dot.
        for part in parts {
            if let duration = blockRest(part, lineCount: region.lineCount) {
                symbols.append(InkSymbol(parts: [part], center: part.bounds.center, duration: duration, rest: true))
                used.insert(part.index)
            } else if isRestBlock(part) {
                used.insert(part.index)
                result.issues.append(issue(.ambiguousPlacement, "Place the rest block on its whole-rest or half-rest staff line.", [part],
                                           candidates: ["Whole rest", "Half rest"]))
            }
        }
        for part in parts where !used.contains(part.index) {
            if eighthRest(part.points) {
                symbols.append(InkSymbol(parts: [part], center: part.bounds.center, duration: 8, rest: true))
                used.insert(part.index)
            } else if quarterRest(part) {
                symbols.append(InkSymbol(parts: [part], center: part.bounds.center, duration: 4, rest: true))
                used.insert(part.index)
            }
        }

        let heads = parts.filter { !used.contains($0.index) && headKind($0) != nil }
            .sorted { $0.bounds.area > $1.bounds.area }
        for head in heads where !used.contains(head.index) {
            var members = [head]
            var filled = headKind(head) == .filled
            // An outline followed by interior filling remains one notehead.
            for part in parts where part.index != head.index && !used.contains(part.index) {
                if head.bounds.contains(part.bounds, margin: 0.08), part.length > 0.2 {
                    members.append(part)
                    filled = true
                }
            }
            let stems = parts.filter { !used.contains($0.index) && isStem($0)
                && stemTouchesHead($0, head.bounds) }
            guard stems.count <= 1 else {
                let group = members + stems
                used.formUnion(group.map(\.index))
                result.issues.append(issue(.ambiguousSymbol, "This head touches several stems. Separate the notes or edit the strokes.", group,
                                           candidates: ["Separate notes", "Chord or overlapping strokes"]))
                continue
            }
            if let stem = stems.first { members.append(stem) }
            let flags = stems.first.map { stem in
                parts.filter { !used.contains($0.index) && !members.map(\.index).contains($0.index)
                    && isFlag($0, stem: stem, head: head.bounds) }
            } ?? []
            members.append(contentsOf: flags)
            used.formUnion(members.map(\.index))
            guard flags.count <= 1, flags.isEmpty || filled else {
                result.issues.append(issue(.ambiguousSymbol, "This head and flag combination needs correction.", members,
                                           candidates: ["Half note", "Eighth note"]))
                continue
            }
            guard stems.first != nil || !filled else {
                result.issues.append(issue(.ambiguousSymbol, "Add a stem to the filled notehead.", members,
                                           candidates: ["Quarter note", "Eighth note"]))
                continue
            }
            let duration = stems.isEmpty ? 1 : (filled ? (flags.isEmpty ? 4 : 8) : 2)
            symbols.append(InkSymbol(parts: members, center: head.bounds.center, duration: duration, rest: false))
        }

        symbols.sort { $0.center.x < $1.center.x }
        for index in symbols.indices {
            let nearbyDots = parts.filter { part in
                !used.contains(part.index) && isDot(part) && part.bounds.center.x > symbols[index].center.x + 0.55
                    && part.bounds.center.x < symbols[index].center.x + 1.8
                    && abs(part.bounds.center.y - symbols[index].center.y) < 0.6
                    && (index + 1 == symbols.count || part.bounds.center.x < symbols[index + 1].center.x - 0.5)
            }.sorted { $0.bounds.center.x < $1.bounds.center.x }
            if nearbyDots.count <= 2 {
                symbols[index].dots = nearbyDots.count
                symbols[index].parts.append(contentsOf: nearbyDots)
                used.formUnion(nearbyDots.map(\.index))
            }
            if index > 0, symbols[index].center.x - symbols[index - 1].center.x < 0.8 {
                result.issues.append(issue(.ambiguousSymbol, "These symbols overlap horizontally. Chords and tightly packed notes need correction.",
                                           symbols[index - 1].parts + symbols[index].parts))
            }
            let symbol = symbols[index]
            let step = symbol.center.y * 2
            if !symbol.rest && abs(step - step.rounded()) > 0.38 {
                result.issues.append(issue(.ambiguousPlacement, "The notehead is between two staff positions. Move or redraw it.", symbol.parts,
                                           candidates: ["Staff step \(Int(floor(step)))", "Staff step \(Int(ceil(step)))"]))
                continue
            }
            let ids = uniqueSources(symbol.parts)
            let event = MusicRecognizedEvent(id: ids[0], sourceStrokeIDs: ids,
                                            centerX: region.left + symbol.center.x * spacing,
                                            staffStep: symbol.rest ? nil : Int(step.rounded()),
                                            durationCode: symbol.duration, dots: symbol.dots, isRest: symbol.rest)
            result.events.append(event)
            result.recognizedDurationTicks += event.durationTicks(quarterNoteTicks: region.quarterNoteTicks)
        }

        let unknown = parts.filter { !used.contains($0.index) }
        if !unknown.isEmpty {
            result.issues.append(issue(.unsupportedSymbol, "Some strokes are unclear or outside the supported note and rest vocabulary. Keep the ink and correct them.", unknown))
        }
        if result.recognizedDurationTicks > region.measureDurationTicks {
            result.issues.append(.init(kind: .rhythmOverflow, message: "The recognized notes and rests exceed the measure's duration."))
        }
        return result
    }

    private static func valid(_ region: MusicWritingRegion) -> Bool {
        [region.left, region.right, region.top, region.bottom, region.staffTopY, region.staffHalfStepY].allSatisfy(\.isFinite)
            && region.left < region.right && region.top < region.bottom && region.staffHalfStepY > 0
            && (region.right - region.left).isFinite && (region.bottom - region.top).isFinite
            && (region.staffHalfStepY * 2).isFinite
            && [1, 5].contains(region.lineCount) && region.measureDurationTicks > 0
            && region.quarterNoteTicks > 0 && region.quarterNoteTicks <= Int.max / 4096
            && region.quarterNoteTicks.isMultiple(of: 8)
    }

    private static func issue(_ kind: MusicInkIssue.Kind, _ message: String, _ parts: [InkPart], candidates: [String] = []) -> MusicInkIssue {
        .init(kind: kind, message: message, sourceStrokeIDs: uniqueSources(parts), candidates: candidates)
    }

    private static func uniqueSources(_ parts: [InkPart]) -> [UUID] {
        var found = Set<UUID>()
        return parts.map(\.source).filter { found.insert($0).inserted }
    }

    private static func resample(_ points: [InkPoint]) -> [InkPoint] {
        var clean: [InkPoint] = []
        for point in points where clean.last.map({ distance($0, point) > 0.008 }) ?? true {
            clean.append(point)
        }
        guard clean.count > 1 else { return clean }
        let length = pathLength(clean)
        guard length > 0.02 else { return [clean[0]] }
        let count = min(96, max(12, Int(min(length * 20, 96))))
        let interval = length / Double(count - 1)
        var output = [clean[0]]
        var segment = 1
        var startDistance = 0.0
        for index in 1..<(count - 1) {
            let target = Double(index) * interval
            while segment < clean.count - 1 && startDistance + distance(clean[segment - 1], clean[segment]) < target {
                startDistance += distance(clean[segment - 1], clean[segment])
                segment += 1
            }
            let a = clean[segment - 1]
            let b = clean[segment]
            let ratio = (target - startDistance) / distance(a, b)
            output.append(InkPoint(x: a.x + (b.x - a.x) * ratio, y: a.y + (b.y - a.y) * ratio))
        }
        output.append(clean[clean.count - 1])
        return output
    }

    private static func splitHeadAndStem(_ points: [InkPoint]) -> [[InkPoint]] {
        guard points.count >= 8 else { return [points] }
        let temporaryID = UUID()
        var best: (head: [InkPoint], stem: [InkPoint], length: Double)?
        for index in 3..<(points.count - 3) {
            let prefix = Array(points[...index])
            let suffix = Array(points[index...])
            for pair in [(prefix, suffix), (suffix, prefix)] {
                let head = InkPart(index: 0, source: temporaryID, points: pair.0)
                let stem = InkPart(index: 1, source: head.source, points: pair.1)
                if headKind(head) != nil && isStem(stem) && stemTouchesHead(stem, head.bounds)
                    && stem.bounds.height > (best?.length ?? 0) {
                    best = (pair.0, pair.1, stem.bounds.height)
                }
            }
        }
        return best.map { [$0.head, $0.stem] } ?? [points]
    }

    private enum HeadKind { case open, filled }

    private static func headKind(_ part: InkPart) -> HeadKind? {
        let box = part.bounds
        guard box.width >= 0.45, box.width <= 1.9, box.height >= 0.28, box.height <= 1.15,
              box.width / box.height >= 0.8, box.width / box.height <= 3.4 else { return nil }
        let endGap = distance(part.points[0], part.points[part.points.count - 1])
        let interior = part.points.filter { point in
            let dx = (point.x - box.center.x) / (box.width / 2)
            let dy = (point.y - box.center.y) / (box.height / 2)
            return dx * dx + dy * dy < 0.42
        }.count
        if endGap < box.width * 0.36 && part.length > (box.width + box.height) * 1.05 {
            return Double(interior) / Double(part.points.count) > 0.14 ? .filled : .open
        }
        if part.length <= hypot(box.width, box.height) * 1.22 && box.height <= 0.8 {
            return .filled
        }
        if part.length > box.width * 2.1 && Double(interior) / Double(part.points.count) > 0.2 {
            return .filled
        }
        return nil
    }

    private static func isStem(_ part: InkPart) -> Bool {
        part.bounds.width <= 0.3 && part.bounds.height >= 1.65 && part.bounds.height <= 5.5
            && part.length <= part.bounds.height * 1.15
    }

    private static func stemTouchesHead(_ stem: InkPart, _ head: InkBounds) -> Bool {
        let ends = [stem.points[0], stem.points[stem.points.count - 1]]
        return ends.contains { point in
            abs(point.y - head.center.y) <= 0.5
                && min(abs(point.x - head.left), abs(point.x - head.right)) <= 0.35
        }
    }

    private static func isFlag(_ part: InkPart, stem: InkPart, head: InkBounds) -> Bool {
        let a = stem.points[0]
        let b = stem.points[stem.points.count - 1]
        let tip = abs(a.y - head.center.y) > abs(b.y - head.center.y) ? a : b
        let towardHead = head.center.y > tip.y ? 1.0 : -1.0
        guard part.bounds.width >= 0.3, part.bounds.width <= 1.5,
              part.bounds.height >= 0.55, part.bounds.height <= 2.2,
              min(distance(part.points[0], tip), distance(part.points[part.points.count - 1], tip)) < 0.45 else { return false }
        let away = part.points.max { ($0.y - tip.y) * towardHead < ($1.y - tip.y) * towardHead }!
        return (away.y - tip.y) * towardHead >= 0.55
            && part.length > distance(part.points[0], part.points[part.points.count - 1]) * 1.12
    }

    private static func blockRest(_ part: InkPart, lineCount: Int) -> Int? {
        guard isRestBlock(part) else { return nil }
        let box = part.bounds
        let hangingLine = lineCount == 1 ? 0.0 : 1.0
        let sittingLine = lineCount == 1 ? 0.0 : 2.0
        if abs(box.top - hangingLine) <= 0.12 { return 1 }
        if abs(box.bottom - sittingLine) <= 0.12 { return 2 }
        return nil
    }

    private static func isRestBlock(_ part: InkPart) -> Bool {
        let box = part.bounds
        guard box.width >= 0.7, box.width <= 1.8, box.height >= 0.2, box.height <= 0.55,
              part.length >= box.width * 1.8 else { return false }
        let corners = Set(part.points.compactMap { point -> Int? in
            let dx = (point.x - box.center.x) / (box.width / 2)
            let dy = (point.y - box.center.y) / (box.height / 2)
            guard abs(dx) > 0.8 && abs(dy) > 0.8 else { return nil }
            return (dx > 0 ? 1 : 0) + (dy > 0 ? 2 : 0)
        })
        return corners.count >= 3
    }

    private static func quarterRest(_ part: InkPart) -> Bool {
        let box = part.bounds
        guard box.width >= 0.35, box.width <= 1.2, box.height >= 1.6, box.height <= 3.6,
              part.length > box.height * 1.13,
              abs(part.points.last!.y - part.points[0].y) >= box.height * 0.7 else { return false }
        var anchor = part.points[0].x
        var previousDirection = 0
        var turns = 0
        for point in part.points where abs(point.x - anchor) >= 0.2 {
            let direction = point.x > anchor ? 1 : -1
            if previousDirection != 0 && direction != previousDirection { turns += 1 }
            previousDirection = direction
            anchor = point.x
        }
        return turns >= 2
    }

    private static func eighthRest(_ points: [InkPoint]) -> Bool {
        guard points.count >= 12 else { return false }
        let temporaryID = UUID()
        for index in 6..<(points.count - 4) {
            let bulb = InkPart(index: 0, source: temporaryID, points: Array(points[...index]))
            let tail = InkPart(index: 1, source: bulb.source, points: Array(points[index...]))
            if bulb.bounds.width >= 0.25 && bulb.bounds.width <= 0.65
                && bulb.bounds.height >= 0.2 && bulb.bounds.height <= 0.65
                && distance(points[0], points[index]) <= 0.22
                && tail.bounds.height >= 1.2 && tail.bounds.height <= 2.7
                && tail.bounds.width >= 0.4 && tail.bounds.width <= 1.3
                && tail.points.last!.y > tail.points[0].y + 1.1
                && tail.length < hypot(tail.bounds.width, tail.bounds.height) * 1.45 {
                return true
            }
        }
        return false
    }

    private static func isDot(_ part: InkPart) -> Bool {
        part.bounds.width <= 0.28 && part.bounds.height <= 0.28 && part.length <= 0.75
    }

    private static func distance(_ a: InkPoint, _ b: InkPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    private static func pathLength(_ points: [InkPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }
}

private nonisolated struct InkPoint {
    var x: Double
    var y: Double
}

private nonisolated struct InkBounds {
    var left: Double
    var right: Double
    var top: Double
    var bottom: Double
    var width: Double { right - left }
    var height: Double { bottom - top }
    var area: Double { width * height }
    var center: InkPoint { .init(x: (left + right) / 2, y: (top + bottom) / 2) }

    func contains(_ other: InkBounds, margin: Double) -> Bool {
        other.left >= left - margin && other.right <= right + margin
            && other.top >= top - margin && other.bottom <= bottom + margin
    }
}

private nonisolated struct InkPart {
    var index: Int
    var source: UUID
    var points: [InkPoint]
    var bounds: InkBounds {
        .init(left: points.map(\.x).min()!, right: points.map(\.x).max()!,
              top: points.map(\.y).min()!, bottom: points.map(\.y).max()!)
    }
    var length: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) }
    }
}

private nonisolated struct InkSymbol {
    var parts: [InkPart]
    var center: InkPoint
    var duration: Int
    var rest: Bool
    var dots = 0
}
