import Foundation
import CoreLocation

// MARK: - Calculator

/// 銀河系中心の可視性と夜間観測ウィンドウを計算する天文ユーティリティ。
enum MilkyWayCalculator {
    enum Constants {
        static let sampleIntervalMinutes = 15
        static let sampleIntervalSeconds = TimeInterval(sampleIntervalMinutes * 60)
        static let secondsPerDay: TimeInterval = 86400
        /// 近接ウィンドウをマージするギャップ許容値（秒）
        /// 根拠: 銀河系中心が高度10°以下に短時間沈むケースや一時的な雲の通過を
        ///       連続した観測ウィンドウとして扱うための許容値。AstroModels と共有。
        static let windowMergeGapSeconds: TimeInterval = 30 * 60
    }

    // 銀河系中心の赤経・赤緯 (J2000.0)
    // RA: 17h 45m 40.04s = 266.41683°, Dec: -29° 00' 28.1" = -29.00781°
    static let gcRA: Double = 266.41683
    static let gcDec: Double = -29.00781

    // ユリウス日の計算
    static func julianDate(from date: Date) -> Double {
        return date.timeIntervalSince1970 / 86400.0 + 2440587.5
    }

    // グリニッジ恒星時 (度)
    static func greenwichSiderealTime(jd: Double) -> Double {
        let T = (jd - AngleMath.j2000JulianDate) / 36525.0
        let gst = 280.46061837
            + 360.98564736629 * (jd - AngleMath.j2000JulianDate)
            + 0.000387933 * T * T
            - T * T * T / 38710000.0
        return AngleMath.normalizedDegrees(gst)
    }

    // 地方恒星時 (度)
    static func localSiderealTime(jd: Double, longitude: Double) -> Double {
        AngleMath.normalizedDegrees(greenwichSiderealTime(jd: jd) + longitude)
    }

    // 赤経・赤緯から高度と方位角をまとめて計算 (度)
    // 高度と方位角を個別に計算すると中間値を2回計算してしまうため、
    // 1回の呼び出しで両方を返す統合関数。ホットループ (星9,000+ 件) で使用する。
    static func altAz(ra: Double, dec: Double, latitude: Double, lst: Double) -> (alt: Double, az: Double) {
        let latRad = AngleMath.toRadians(latitude)
        return altAzFast(ra: ra, dec: dec, cosLat: cos(latRad), sinLat: sin(latRad), lst: lst)
    }

    /// lat の sin/cos を呼び出し元で事前計算してから渡すバッチ高速版。
    /// 多数の天体を同一緯度で一括変換するホットループ（星 25,000+ 件）で使用する。
    static func altAzFast(ra: Double, dec: Double,
                          cosLat: Double, sinLat: Double,
                          lst: Double) -> (alt: Double, az: Double) {
        var ha = lst - ra
        ha = ha.truncatingRemainder(dividingBy: 360.0)

        let haRad  = ha  * .pi / 180.0
        let decRad = dec * .pi / 180.0

        let cosDec = cos(decRad)
        let sinDec = sin(decRad)
        let cosHa  = cos(haRad)
        let sinHa  = sin(haRad)

        let sinAlt = sinLat * sinDec + cosLat * cosDec * cosHa
        let altRad = asin(max(-1, min(1, sinAlt)))
        let alt    = altRad * 180.0 / .pi

        let cosAlt = cos(altRad)
        guard cosAlt > 1e-10 else { return (alt, 0.0) }

        let sinA = -sinHa * cosDec / cosAlt
        let cosA = (sinDec - sinLat * sinAlt) / (cosLat * cosAlt)
        var az = atan2(sinA, cosA) * 180.0 / .pi
        if az < 0 { az += 360.0 }
        return (alt, az)
    }

    /// 同じ緯度・地方恒星時で多数の天体を変換するため、altAzFast の観測者側の引数をまとめて持つ。
    struct HorizontalObserver: Sendable {
        let cosLat: Double
        let sinLat: Double
        let lst: Double

        @inline(__always)
        func altAz(ra: Double, dec: Double) -> (alt: Double, az: Double) {
            MilkyWayCalculator.altAzFast(ra: ra, dec: dec, cosLat: cosLat, sinLat: sinLat, lst: lst)
        }
    }

    // 赤経・赤緯から高度を計算 (度)
    static func altitude(ra: Double, dec: Double, latitude: Double, lst: Double) -> Double {
        altAz(ra: ra, dec: dec, latitude: latitude, lst: lst).alt
    }

    // 指定した日付・場所で15分おきにイベントを計算
    static func calculateEvents(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> [AstroEvent] {
        var events: [AstroEvent] = []
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let observationDate = calendar.startOfDay(for: date)
        let samplingStart = calendar.date(byAdding: .hour, value: 12, to: observationDate)
            ?? observationDate.addingTimeInterval(12 * 60 * 60)
        let latRad = AngleMath.toRadians(location.latitude)
        let cosLat = cos(latRad)
        let sinLat = sin(latRad)

        for minutes in stride(from: 0, to: 24 * 60, by: Constants.sampleIntervalMinutes) {
            let sampleDate = samplingStart.addingTimeInterval(Double(minutes) * 60)
            let jd = julianDate(from: sampleDate)
            let lst = localSiderealTime(jd: jd, longitude: location.longitude)
            let observer = HorizontalObserver(cosLat: cosLat, sinLat: sinLat, lst: lst)

            let (gcAlt, gcAz) = observer.altAz(ra: gcRA, dec: gcDec)

            let sun = sunRaDec(jd: jd)
            let sunAlt = observer.altAz(ra: sun.ra, dec: sun.dec).alt

            let moon = moonRaDec(jd: jd)
            let moonAlt = observer.altAz(ra: moon.ra, dec: moon.dec).alt

            events.append(AstroEvent(
                date: sampleDate,
                galacticCenterAltitude: gcAlt,
                galacticCenterAzimuth: gcAz,
                sunAltitude: sunAlt,
                moonAltitude: moonAlt,
                moonPhase: moon.phase
            ))
        }
        return events
    }

    // 指定した日付のナイトサマリーを計算
    static func calculateNightSummary(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> NightSummary {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let observationDate = calendar.startOfDay(for: date)
        let events = calculateEvents(date: observationDate, location: location, timeZone: timeZone)
        let windows = findViewingWindows(events: events)

        // 深夜0時の月の位相
        let midnight = calendar.date(
            byAdding: .day,
            value: 1,
            to: observationDate
        ) ?? observationDate.addingTimeInterval(Constants.secondsPerDay)
        let moonAtMidnight = moonRaDec(jd: julianDate(from: midnight))

        return NightSummary(
            date: observationDate,
            location: location,
            events: events,
            viewingWindows: windows,
            moonPhaseAtMidnight: moonAtMidnight.phase,
            timeZoneIdentifier: timeZone.identifier
        )
    }

    // 今後N日間の各夜のサマリーを計算
    static func calculateUpcomingNights(
        from startDate: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone,
        days: Int = 9
    ) -> [NightSummary] {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let observationStartDate = calendar.startOfDay(for: startDate)
        return (0..<days).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: observationStartDate) ?? observationStartDate
            return calculateNightSummary(date: date, location: location, timeZone: timeZone)
        }
    }
}
