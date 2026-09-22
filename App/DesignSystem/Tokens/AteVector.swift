import CoreGraphics
import SwiftUI

/// **The prototype's drawings, as paths.**
///
/// `design/v1` draws its own icon set — 24-unit viewBox, 1.8 stroke, round caps and joins — and the
/// only way to be identical to it is to carry its geometry rather than the nearest SF Symbol. The
/// artboards hold that geometry as SVG (`d` strings, `<rect rx>`, `<circle>`), so this file reads
/// exactly that: the icon table below is a copy-paste of the markup, which is what keeps the two
/// from drifting.
///
/// Only the subset the artboards actually use is supported — `M L H V C S A Z` and their relative
/// forms, with circular arcs (every arc in the set has `rx == ry` and no rotation). Anything else is
/// skipped rather than guessed at.
enum AteVector {

    /// The design's coordinate space. Every path below is written in it and scaled at draw time.
    static let viewBox: CGFloat = 24

    /// A rounded rectangle, as `<rect x y width height rx>`.
    static func rectangle(
        _ originX: CGFloat, _ originY: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat
    ) -> Path {
        Path(roundedRect: CGRect(x: originX, y: originY, width: width, height: height), cornerRadius: radius)
    }

    /// A circle, as `<circle cx cy r>`.
    static func circle(_ centreX: CGFloat, _ centreY: CGFloat, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: centreX - radius, y: centreY - radius, width: radius * 2, height: radius * 2
        ))
    }

    /// An SVG `d` attribute, verbatim.
    static func path(_ data: String) -> Path {
        var parser = PathParser(data)
        return parser.parse()
    }
}

// MARK: - The parser

/// Walks an SVG `d` string once, left to right, keeping the current point and the last control point
/// (which is what `S` reflects). Deliberately small: it exists to read a table of eighteen icons, not
/// to be an SVG renderer.
private struct PathParser {
    private let characters: [Character]
    private var index = 0
    private var path = Path()
    private var current = CGPoint.zero
    private var subpathStart = CGPoint.zero
    private var lastControl: CGPoint?
    private var command: Character = "M"

    init(_ data: String) {
        characters = Array(data)
    }

    mutating func parse() -> Path {
        while true {
            skipSeparators()
            guard index < characters.count else { break }
            if characters[index].isLetter {
                command = characters[index]
                index += 1
            }
            guard run(command) else { break }
        }
        return path
    }

    // swiftlint:disable:next cyclomatic_complexity
    private mutating func run(_ command: Character) -> Bool {
        let isRelative = command.isLowercase
        switch command.lowercased().first {
        case "m":
            guard let point = point(isRelative) else { return false }
            path.move(to: point)
            current = point
            subpathStart = point
            lastControl = nil
            // A second coordinate pair after `M` is an implicit `L`.
            self.command = isRelative ? "l" : "L"
        case "l":
            guard let point = point(isRelative) else { return false }
            path.addLine(to: point)
            current = point
            lastControl = nil
        case "h":
            guard let step = number() else { return false }
            let point = CGPoint(x: isRelative ? current.x + step : step, y: current.y)
            path.addLine(to: point)
            current = point
            lastControl = nil
        case "v":
            guard let step = number() else { return false }
            let point = CGPoint(x: current.x, y: isRelative ? current.y + step : step)
            path.addLine(to: point)
            current = point
            lastControl = nil
        case "c":
            guard let one = point(isRelative), let two = point(isRelative),
                  let end = point(isRelative) else { return false }
            path.addCurve(to: end, control1: one, control2: two)
            current = end
            lastControl = two
        case "s":
            guard let two = point(isRelative), let end = point(isRelative) else { return false }
            // `S` reflects the previous curve's second control point through the current point.
            let one = lastControl.map {
                CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
            } ?? current
            path.addCurve(to: end, control1: one, control2: two)
            current = end
            lastControl = two
        case "a":
            guard let radius = number(), number() != nil, number() != nil,
                  let largeArc = flag(), let sweep = flag(), let end = point(isRelative) else { return false }
            addArc(to: end, radius: radius, largeArc: largeArc, sweep: sweep)
            current = end
            lastControl = nil
        case "z":
            path.closeSubpath()
            current = subpathStart
            lastControl = nil
        default:
            return false
        }
        return true
    }

    /// A circular arc, approximated in ≤90° cubic segments. Written out rather than handed to
    /// `Path.addArc` because that API's `clockwise:` means the opposite thing in a y-down space, and
    /// a silently mirrored pin is exactly the kind of difference this file exists to prevent.
    private mutating func addArc(to end: CGPoint, radius: CGFloat, largeArc: Bool, sweep: Bool) {
        let start = current
        let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let distance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard distance > 0 else { return }
        // An `r` too small for the chord is grown to fit, as SVG requires.
        let radius = max(radius, distance / 2)
        let height = max(0, radius * radius - distance * distance / 4).squareRoot()
        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let centre = CGPoint(
            x: (start.x + end.x) / 2 + sign * height * (-delta.y / distance),
            y: (start.y + end.y) / 2 + sign * height * (delta.x / distance)
        )
        var from = atan2(start.y - centre.y, start.x - centre.x)
        let to = atan2(end.y - centre.y, end.x - centre.x)
        var sweepAngle = to - from
        if sweep, sweepAngle < 0 { sweepAngle += 2 * .pi }
        if sweep == false, sweepAngle > 0 { sweepAngle -= 2 * .pi }

        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let step = sweepAngle / CGFloat(segments)
        let alpha = 4.0 / 3.0 * tan(step / 4)
        for _ in 0..<segments {
            let next = from + step
            let one = CGPoint(x: centre.x + radius * cos(from), y: centre.y + radius * sin(from))
            let two = CGPoint(x: centre.x + radius * cos(next), y: centre.y + radius * sin(next))
            path.addCurve(
                to: two,
                control1: CGPoint(x: one.x - alpha * radius * sin(from), y: one.y + alpha * radius * cos(from)),
                control2: CGPoint(x: two.x + alpha * radius * sin(next), y: two.y - alpha * radius * cos(next))
            )
            from = next
        }
    }

    // MARK: Lexing

    private mutating func point(_ isRelative: Bool) -> CGPoint? {
        guard let px = number(), let py = number() else { return nil }
        return isRelative ? CGPoint(x: current.x + px, y: current.y + py) : CGPoint(x: px, y: py)
    }

    /// An arc's two flags are single digits and may run straight into the next number (`0 0 1 3 3`
    /// and `0013 3` are the same thing), so they are read a character at a time.
    private mutating func flag() -> Bool? {
        skipSeparators()
        guard index < characters.count, let value = characters[index].wholeNumberValue else { return nil }
        index += 1
        return value == 1
    }

    private mutating func number() -> CGFloat? {
        skipSeparators()
        var digits = ""
        if index < characters.count, characters[index] == "-" || characters[index] == "+" {
            digits.append(characters[index])
            index += 1
        }
        // At most one decimal point: `l.06.06` is two numbers, not one, and SVG leans on that.
        var hasPoint = false
        while index < characters.count {
            let character = characters[index]
            if character == "." {
                if hasPoint { break }
                hasPoint = true
            } else if character.isNumber == false {
                break
            }
            digits.append(character)
            index += 1
        }
        guard let value = Double(digits) else { return nil }
        return CGFloat(value)
    }

    private mutating func skipSeparators() {
        while index < characters.count, characters[index] == " " || characters[index] == "," {
            index += 1
        }
    }
}
