import Foundation

/// Parsing a Postgres `timestamptz` the way PostgREST writes it.
///
/// **Hand-rolled on purpose**, and it is the same reason ``PostgRESTTimestamp`` is: Postgres keeps
/// *microseconds* and the seeded rows land on them (`…:25.240956+00:00`). `ISO8601DateFormatter`
/// truncates to milliseconds, `ISO8601FormatStyle` is strict about how many fractional digits it
/// will accept, and a date that is a quarter of a millisecond off is a keyset cursor that matches
/// nothing. A short scanner that reads exactly the shapes PostgREST emits is both cheaper and
/// harder to get wrong.
///
/// Accepts `YYYY-MM-DD` followed by `T` or a space, `HH:MM:SS`, optional `.ffffff` to any number of
/// digits, and an optional `Z`, `±HH`, `±HHMM` or `±HH:MM`. A missing zone is read as UTC, which is
/// what `timestamptz` means on the wire.
public enum PostgRESTDate {
    /// A `JSONDecoder` that reads every date this way. Use it wherever entry rows are decoded, so
    /// the app is not relying on how someone else's client happened to configure its decoder.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = parse(raw) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "not a PostgREST timestamp: \(raw)"
                ))
            }
            return date
        }
        return decoder
    }()

    public static func parse(_ raw: String) -> Date? {
        var scanner = Scanner(raw)
        guard let year = scanner.integer(4), scanner.take("-"),
              let month = scanner.integer(2), scanner.take("-"),
              let day = scanner.integer(2) else { return nil }
        guard scanner.take("T") || scanner.take(" ") else { return calendarDate(year, month, day, 0, 0, 0, 0, 0) }
        guard let hour = scanner.integer(2), scanner.take(":"),
              let minute = scanner.integer(2) else { return nil }
        let second = scanner.take(":") ? (scanner.integer(2) ?? 0) : 0

        var fraction: Double = 0
        if scanner.take(".") {
            let digits = scanner.digits()
            if digits.isEmpty == false, let value = Double("0." + digits) { fraction = value }
        }

        let offset = scanner.zoneOffsetSeconds()
        return calendarDate(year, month, day, hour, minute, second, fraction, offset)
    }

    // A tolerable arity for one private assembler; splitting it would only scatter the pieces.
    // swiftlint:disable:next function_parameter_count
    private static func calendarDate(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int, _ second: Int,
        _ fraction: Double, _ offsetSeconds: Int
    ) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let whole = calendar.date(from: components) else { return nil }
        return whole.addingTimeInterval(fraction - Double(offsetSeconds))
    }

    /// A tiny forward-only reader. `Scanner` from Foundation would do, but it is a class with
    /// locale-sensitive number parsing, and neither is welcome in a timestamp parser.
    private struct Scanner {
        private let units: [UInt8]
        private var index = 0

        init(_ string: String) {
            self.units = Array(string.utf8)
        }

        mutating func take(_ character: Character) -> Bool {
            guard let byte = character.asciiValue, index < units.count, units[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func integer(_ length: Int) -> Int? {
            guard index + length <= units.count else { return nil }
            var value = 0
            for offset in 0..<length {
                let unit = units[index + offset]
                guard unit >= 48, unit <= 57 else { return nil }
                value = value * 10 + Int(unit - 48)
            }
            index += length
            return value
        }

        mutating func digits() -> String {
            var collected = ""
            while index < units.count, units[index] >= 48, units[index] <= 57 {
                collected.append(Character(Unicode.Scalar(units[index])))
                index += 1
            }
            return collected
        }

        /// `Z`, `±HH`, `±HHMM`, `±HH:MM`, or nothing (which means UTC).
        mutating func zoneOffsetSeconds() -> Int {
            if take("Z") || take("z") { return 0 }
            let sign: Int
            if take("+") {
                sign = 1
            } else if take("-") {
                sign = -1
            } else {
                return 0
            }
            guard let hours = integer(2) else { return 0 }
            _ = take(":")
            let minutes = integer(2) ?? 0
            return sign * (hours * 3600 + minutes * 60)
        }
    }
}
