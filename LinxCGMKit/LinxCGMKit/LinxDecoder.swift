import Foundation

public enum LinxReadingSource: Equatable {
    case advertisement
    case gatt
}

/// A decoded Linx reading.
public struct LinxGlucoseReading: Equatable {
    public let receivedAt: Date
    public let glucoseMgdl: Int
    public let trend: Int // 0..3 (idx7 >>10 &3)
    public let raw10: Int // raw glu10 (for calibration)
    public let serial: String?
    public let rawHex: String
    public let source: LinxReadingSource

    public var glucoseMmol: Double { Double(glucoseMgdl) / 18.0 }
}

/// A calibration point: raw glu10 + user-provided reference blood glucose
/// (mmol/L). Persisted in the plugin state.
public struct LinxCalPoint: Codable, Equatable {
    public let glu10: Int
    public let mmol: Double
    public let date: Date

    public init(glu10: Int, mmol: Double, date: Date = Date()) {
        self.glu10 = glu10
        self.mmol = mmol
        self.date = date
    }
}

/// Outcome of trying to add a calibration point.
public enum LinxCalibrationResult: Equatable {
    case accepted
    /// Reference outside 40–400 mg/dL (2.2–22.2 mmol/L).
    case rejectedReferenceOutOfRange
    /// Reference differs too much from the current sensor value.
    case rejectedTooFarFromSensor
    /// The resulting curve would be implausible (slope too far from the base curve).
    case rejectedImplausibleCurve
    /// No current sensor value to calibrate against.
    case rejectedNoReading
}

/// Two-point calibration: mmol = calA * glu10 + calB.
/// Proven, full-day-tested logic carried over 1:1.
public struct LinxCalibration: Equatable {
    // ✅ PROVEN BASE CURVE (2026-06-18). The previous, working app was calibrated
    // with two real reference points, and this matched the factory Linx curve
    // accurately for a full day:
    //   raw 108 -> 5.8 mmol
    //   raw 134 -> 7.5 mmol
    //   Active curve: mmol = 0.06538 * raw - 1.2615
    // Check: glu10≈137 -> 0.06538*137-1.2615 = 7.69 mmol ≈ factory Linx 7.8.
    //
    // The previous 0.01667 base slope was ~4× flatter → everything was
    // suppressed (showed 5.6 instead of 7.8). Raw decoding (glu10) was correct
    // all along; only this base curve was wrong. The standalone LinxReader app
    // baked in the same curve.
    public static let defaultCalA: Double = 0.06538
    public static let defaultCalB: Double = -1.2615
    /// Identity curve for an already calibrated GATT mg/dL value expressed as mmol/L.
    public static let gattDefaultCalA: Double = 1.0 / 18.0
    public static let gattDefaultCalB: Double = 0

    public var calA: Double
    public var calB: Double
    public var points: [LinxCalPoint]

    public init(
        calA: Double = LinxCalibration.defaultCalA,
        calB: Double = LinxCalibration.defaultCalB,
        points: [LinxCalPoint] = []
    ) {
        self.calA = calA
        self.calB = calB
        self.points = points
    }

    public static var gattDefault: LinxCalibration {
        LinxCalibration(calA: gattDefaultCalA, calB: gattDefaultCalB)
    }

    /// Accepted reference range for a calibration point (mmol/L, ~40–400 mg/dL).
    public static let referenceRangeMmol: ClosedRange<Double> = 2.2 ... 22.2
    /// A reference may not differ from the current sensor value by more than this
    /// (mmol/L, ~100 mg/dL). Larger gaps almost always mean a typo or a wrong unit.
    public static let maxReferenceDeltaMmol: Double = 5.5
    /// Allowed slope relative to the base (factory/default) slope.
    public static let allowedSlopeRatio: ClosedRange<Double> = 0.7 ... 1.3

    /// Add a new reference point. We keep the 2 most recent.
    ///
    /// Safety: the point is only accepted if the reference is plausible and the
    /// resulting curve stays within `allowedSlopeRatio` of `baseSlope`. Two points
    /// whose inputs are closer than `minInputSpan` are not used to fit a slope
    /// (the fit would be dominated by noise); the newest point then only
    /// corrects the offset.
    @discardableResult
    public mutating func addPoint(
        glu10: Int,
        mmol: Double,
        baseSlope: Double,
        minInputSpan: Int
    ) -> LinxCalibrationResult {
        guard LinxCalibration.referenceRangeMmol.contains(mmol) else {
            return .rejectedReferenceOutOfRange
        }
        let currentMmol = self.mmol(forRaw10: glu10)
        guard abs(mmol - currentMmol) <= LinxCalibration.maxReferenceDeltaMmol else {
            return .rejectedTooFarFromSensor
        }

        var candidate = self
        candidate.points.append(LinxCalPoint(glu10: glu10, mmol: mmol))
        if candidate.points.count > 2 { candidate.points = Array(candidate.points.suffix(2)) }
        candidate.recompute(minInputSpan: minInputSpan)

        guard candidate.calA.isFinite, candidate.calB.isFinite,
              baseSlope > 0,
              LinxCalibration.allowedSlopeRatio.contains(candidate.calA / baseSlope)
        else {
            return .rejectedImplausibleCurve
        }
        self = candidate
        return .accepted
    }

    /// Reset to factory default calibration.
    public mutating func reset() {
        points = []
        calA = LinxCalibration.defaultCalA
        calB = LinxCalibration.defaultCalB
    }

    /// Recomputes calA/calB from the points.
    ///  - 2 points whose inputs differ by at least `minInputSpan` -> two-point fit
    ///  - otherwise -> single-point: keep slope, adjust offset so the newest
    ///    point is exact
    public mutating func recompute(minInputSpan: Int = 1) {
        if points.count >= 2, abs(points[0].glu10 - points[1].glu10) >= max(minInputSpan, 1) {
            let (p1, p2) = (points[0], points[1])
            let a = (p2.mmol - p1.mmol) / Double(p2.glu10 - p1.glu10)
            let b = p1.mmol - a * Double(p1.glu10)
            calA = a
            calB = b
        } else if let p = points.last {
            calB = p.mmol - calA * Double(p.glu10)
        }
    }

    /// Compute mmol from raw glu10.
    public func mmol(forRaw10 glu10: Int) -> Double {
        calA * Double(glu10) + calB
    }
}

public enum LinxDecoder {
    public static func mmolToMgdl(_ mmol: Double) -> Int { Int((mmol * 18.0).rounded()) }

    /// Decode the standard CGM Session Start Time characteristic (2AAA).
    /// The first seven bytes use the Bluetooth Date Time format, followed by
    /// time-zone and daylight-saving offsets.
    static func decodeCGMSessionStartTime(
        _ payload: Data,
        requiresCRC: Bool
    ) -> Date? {
        let bytes = [UInt8](payload)
        let expectedCount = requiresCRC ? 11 : 9
        guard bytes.count == expectedCount else { return nil }

        if requiresCRC {
            let body = Data(payload.dropLast(2))
            let receivedCRC = UInt16(bytes[9]) | (UInt16(bytes[10]) << 8)
            guard cgmCRC(body) == receivedCRC else { return nil }
        }

        let year = Int(bytes[0]) | (Int(bytes[1]) << 8)
        let month = Int(bytes[2])
        let day = Int(bytes[3])
        let hour = Int(bytes[4])
        let minute = Int(bytes[5])
        let second = Int(bytes[6])

        let timeZoneQuarterHours = Int(Int8(bitPattern: bytes[7]))
        let dstQuarterHours: Int
        switch bytes[8] {
        case 0,
             2,
             4,
             8:
            dstQuarterHours = Int(bytes[8])
        default:
            dstQuarterHours = 0
        }

        let timeZone: TimeZone
        if timeZoneQuarterHours == -128 {
            timeZone = .current
        } else {
            timeZone = TimeZone(
                secondsFromGMT: (timeZoneQuarterHours + dstQuarterHours) * 15 * 60
            ) ?? .current
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)
    }

    /// Decode the standard CGM Session Run Time characteristic (2AAB).
    /// Bluetooth defines this little-endian UInt16 value in hours.
    static func decodeCGMSessionRunTime(
        _ payload: Data,
        requiresCRC: Bool
    ) -> TimeInterval? {
        let bytes = [UInt8](payload)
        let expectedCount = requiresCRC ? 4 : 2
        guard bytes.count == expectedCount else { return nil }

        if requiresCRC {
            let body = Data(payload.dropLast(2))
            let receivedCRC = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
            guard cgmCRC(body) == receivedCRC else { return nil }
        }

        let hours = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard hours > 0, hours != .max else { return nil }
        return TimeInterval(hours) * 60 * 60
    }

    /// CGM E2E-CRC (CRC-CCITT, polynomial 0x1021, initial value 0xFFFF).
    /// The checksum is transmitted least-significant byte first.
    static func cgmCRC(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0 ..< 8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    static func appendingCGMCRC(to data: Data) -> Data {
        let crc = cgmCRC(data)
        var protected = data
        protected.append(UInt8(truncatingIfNeeded: crc))
        protected.append(UInt8(truncatingIfNeeded: crc >> 8))
        return protected
    }

    /// Decode the standard Bluetooth CGM Measurement characteristic (2AA7).
    /// DiaExpert reports its factory-calibrated concentration directly in mg/dL;
    /// applying the legacy Linx advertisement calibration again would distort it.
    static func decodeCGMMeasurement(
        _ payload: Data,
        serial: String?,
        requiresCRC: Bool
    ) -> LinxGlucoseReading? {
        let bytes = [UInt8](payload)
        guard bytes.count >= (requiresCRC ? 8 : 6),
              Int(bytes[0]) == bytes.count
        else { return nil }

        if requiresCRC {
            let body = Data(payload.dropLast(2))
            let receivedCRC = UInt16(bytes[bytes.count - 2])
                | (UInt16(bytes[bytes.count - 1]) << 8)
            guard cgmCRC(body) == receivedCRC else { return nil }
        }

        // IEEE-11073 16-bit SFLOAT: signed 12-bit mantissa and signed
        // 4-bit base-10 exponent, both little-endian on the wire.
        let raw = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        guard ![UInt16(0x07FE), 0x07FF, 0x0800, 0x0801, 0x0802].contains(raw) else {
            return nil
        }
        let rawMantissa = Int(raw & 0x0FFF)
        let mantissa = rawMantissa >= 0x0800 ? rawMantissa - 0x1000 : rawMantissa
        let rawExponent = Int((raw >> 12) & 0x0F)
        let exponent = rawExponent >= 0x08 ? rawExponent - 0x10 : rawExponent
        let concentration = Double(mantissa) * pow(10.0, Double(exponent))
        guard concentration.isFinite else { return nil }

        let glucoseMgdl = Int(concentration.rounded())
        guard (27 ... 540).contains(glucoseMgdl) else { return nil }

        return LinxGlucoseReading(
            receivedAt: Date(),
            glucoseMgdl: glucoseMgdl,
            trend: 0,
            raw10: glucoseMgdl,
            serial: serial,
            rawHex: bytes.map { String(format: "%02X", $0) }.joined(),
            source: .gatt
        )
    }

    /// Returns the decoded reading, or nil on warmup / bad length.
    /// Calibration is supplied externally (from manager state).
    public static func decode(
        manufacturerData mfg: Data,
        advName: String,
        calibration: LinxCalibration
    ) -> LinxGlucoseReading? {
        let b = [UInt8](mfg)
        guard b.count >= 27 else { return nil }

        func le16(_ i: Int) -> Int { Int(b[i]) | (Int(b[i + 1]) << 8) }

        // ── Latest raw glucose (idx 7-8) ──
        let raw16 = le16(7)
        // Warmup sentinel: lower 16 bits are 0xFFFF
        guard raw16 != 0xFFFF else { return nil }

        let glu10 = raw16 & 0x3FF
        let trend = (raw16 >> 10) & 3

        // ── Calibration mmol → mg/dL ──
        let mmol = calibration.mmol(forRaw10: glu10)
        let bg = mmolToMgdl(mmol)

        // Sanity filter (1.5–30 mmol ~ 27–540 mg/dL)
        guard (27 ... 540).contains(bg) else { return nil }

        let hex = b.map { String(format: "%02X", $0) }.joined()

        return LinxGlucoseReading(
            receivedAt: Date(),
            glucoseMgdl: bg,
            trend: trend,
            raw10: glu10,
            serial: advName.isEmpty ? nil : advName,
            rawHex: hex,
            source: .advertisement
        )
    }
}
