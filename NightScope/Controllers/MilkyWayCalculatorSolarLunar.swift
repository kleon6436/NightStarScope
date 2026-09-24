import Foundation
import CoreLocation

extension MilkyWayCalculator {
    // 太陽の視黄経 (rad, 簡易計算)
    private static func sunEclipticLongitude(jd: Double) -> Double {
        let n = jd - AngleMath.j2000JulianDate
        var L = 280.460 + 0.9856474 * n
        let g = AngleMath.toRadians(357.528 + 0.9856003 * n)
        L = L.truncatingRemainder(dividingBy: 360.0)
        return AngleMath.toRadians(L + 1.915 * sin(g) + 0.020 * sin(2 * g))
    }

    // 太陽の赤経・赤緯 (簡易計算)
    static func sunRaDec(jd: Double) -> (ra: Double, dec: Double) {
        let lambdaRad = sunEclipticLongitude(jd: jd)
        let epsilonRad = AngleMath.toRadians(23.439)

        let dec = AngleMath.toDegrees(asin(sin(epsilonRad) * sin(lambdaRad)))
        let raRad = atan2(cos(epsilonRad) * sin(lambdaRad), cos(lambdaRad))
        let ra = AngleMath.normalizedDegrees(AngleMath.toDegrees(raRad))
        return (ra, dec)
    }

    // MARK: - 太陽高度に基づく夜間区間

    /// 観測日 12:00 から翌日 12:00 までで、太陽高度が `threshold` 度を下回る連続区間を返す。
    /// 極夜では 24 時間区間、白夜では nil を返す。
    private static func darknessInterval(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone,
        threshold: Double
    ) -> DateInterval? {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let observationDate = calendar.startOfDay(for: date)
        let samplingStart = calendar.date(byAdding: .hour, value: 12, to: observationDate)
            ?? observationDate.addingTimeInterval(12 * 60 * 60)
        let samplingEnd = samplingStart.addingTimeInterval(Constants.secondsPerDay)
        let latRad = AngleMath.toRadians(location.latitude)
        let cosLat = cos(latRad)
        let sinLat = sin(latRad)

        var darkStart: Date?
        var previousAltitude: Double?

        for minute in 0...24 * 60 {
            let sampleDate = samplingStart.addingTimeInterval(Double(minute) * 60)
            let jd = julianDate(from: sampleDate)
            let lst = localSiderealTime(jd: jd, longitude: location.longitude)
            let sun = sunRaDec(jd: jd)
            let (sunAltitude, _) = altAzFast(
                ra: sun.ra,
                dec: sun.dec,
                cosLat: cosLat,
                sinLat: sinLat,
                lst: lst
            )

            if previousAltitude == nil, sunAltitude < threshold {
                darkStart = samplingStart
            } else if let previousAltitude {
                if darkStart == nil, previousAltitude >= threshold, sunAltitude < threshold {
                    darkStart = sampleDate
                } else if let darkStart, previousAltitude < threshold, sunAltitude >= threshold {
                    return DateInterval(start: darkStart, end: sampleDate)
                }
            }

            previousAltitude = sunAltitude
        }

        guard let darkStart else { return nil }
        return DateInterval(start: darkStart, end: samplingEnd)
    }

    /// 指定日・場所の市民薄明 (太陽高度 -6°) の夜間区間を返す。
    /// 極夜では 24 時間区間、白夜では nil を返す。
    static func civilDarknessInterval(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> DateInterval? {
        darknessInterval(date: date, location: location, timeZone: timeZone, threshold: -6.0)
    }

    /// 指定日・場所の日没〜日の出 (太陽高度 0°) の区間を返す。
    /// 極夜では 24 時間区間、白夜では nil を返す。
    static func sunsetSunriseInterval(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> DateInterval? {
        darknessInterval(date: date, location: location, timeZone: timeZone, threshold: 0.0)
    }

    /// 日没〜日の出の開始/終了 Date を返す。
    static func findSunsetSunrise(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> (sunset: Date, sunrise: Date)? {
        guard let interval = sunsetSunriseInterval(
            date: date,
            location: location,
            timeZone: timeZone
        ) else {
            return nil
        }
        return (sunset: interval.start, sunrise: interval.end)
    }

    /// 日没〜日の出の開始/終了を分単位で返す。
    static func findSunsetSunriseMinutes(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> (sunsetMinutes: Double, sunriseMinutes: Double)? {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let startOfDay = calendar.startOfDay(for: date)
        guard let times = findSunsetSunrise(
            date: date,
            location: location,
            timeZone: timeZone
        ) else {
            return nil
        }

        let sunsetMinutes = times.sunset.timeIntervalSince(startOfDay) / 60
        let sunriseMinutes = times.sunrise.timeIntervalSince(startOfDay) / 60
        return (
            sunsetMinutes: sunsetMinutes.truncatingRemainder(dividingBy: 1_440),
            sunriseMinutes: sunriseMinutes.truncatingRemainder(dividingBy: 1_440)
        )
    }

    // 月の赤経・赤緯・位相 (簡易計算)
    static func moonRaDec(jd: Double) -> (ra: Double, dec: Double, phase: Double) {
        let d = jd - AngleMath.j2000JulianDate

        // 月の平均要素
        let L = (218.316 + 13.176396 * d).truncatingRemainder(dividingBy: 360.0)
        let M = AngleMath.toRadians(134.963 + 13.064993 * d)
        let F = AngleMath.toRadians(93.272 + 13.229350 * d)

        let lambdaRad = AngleMath.toRadians(L + 6.289 * sin(M))
        let betaRad = AngleMath.toRadians(5.128 * sin(F))

        let epsilonRad = AngleMath.toRadians(23.439)

        let (ra, dec) = eclipticToEquatorial(lambda: lambdaRad, beta: betaRad, epsilon: epsilonRad)

        let sunLambdaRad = sunEclipticLongitude(jd: jd)
        let elongation = AngleMath.normalizedDegrees(AngleMath.toDegrees(lambdaRad) - AngleMath.toDegrees(sunLambdaRad))
        let phase = elongation / 360.0

        return (ra, dec, phase)
    }

    /// 黄道座標 (黄経 λ・黄緯 β・黄道傾斜角 ε, いずれも rad) を赤道座標 (度) に変換する。
    static func eclipticToEquatorial(
        lambda: Double,
        beta: Double,
        epsilon: Double
    ) -> (ra: Double, dec: Double) {
        let sinDec = sin(beta) * cos(epsilon) + cos(beta) * sin(epsilon) * sin(lambda)
        let dec = AngleMath.toDegrees(asin(max(-1.0, min(1.0, sinDec))))
        let raRad = atan2(sin(lambda) * cos(epsilon) - tan(beta) * sin(epsilon), cos(lambda))
        return (AngleMath.normalizedDegrees(AngleMath.toDegrees(raRad)), dec)
    }
}
