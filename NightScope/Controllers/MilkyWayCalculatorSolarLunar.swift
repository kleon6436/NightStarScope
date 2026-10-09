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

    /// 日没・日の出の標準的な太陽中心高度 (度)。
    /// 根拠: 地平線での大気差 34′ + 太陽視半径 16′ (USNO / Meeus 15 章)。
    static let standardSunsetAltitude: Double = -0.833

    /// 観測日の南中（太陽高度最大）以降で、太陽高度が `threshold` 度を下回る連続区間を返す。
    /// 極夜（終日 `threshold` 未満）では観測日 12:00 から翌日 12:00 までの 24 時間区間、白夜では nil を返す。
    /// 根拠: 時計の 12:00 から探索すると、高緯度で 12:00 時点に既に日没後の場合に
    ///       日の出前の短い区間を誤って返すため、太陽が最も高い時刻を探索の起点にする。
    private static func darknessInterval(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone,
        threshold: Double
    ) -> DateInterval? {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let observationDate = calendar.startOfDay(for: date)
        let nextObservationDate = calendar.date(byAdding: .day, value: 1, to: observationDate)
            ?? observationDate.addingTimeInterval(Constants.secondsPerDay)
        let latRad = AngleMath.toRadians(location.latitude)
        let cosLat = cos(latRad)
        let sinLat = sin(latRad)

        func sunAltitude(at sampleDate: Date) -> Double {
            let jd = julianDate(from: sampleDate)
            let lst = localSiderealTime(jd: jd, longitude: location.longitude)
            let sun = sunRaDec(jd: jd)
            return altAzFast(ra: sun.ra, dec: sun.dec, cosLat: cosLat, sinLat: sinLat, lst: lst).alt
        }

        // 1) 観測日のうち太陽高度が最大となる時刻（≈南中）を 10 分刻みで探す
        var anchor = observationDate
        var maxAltitude = -Double.infinity
        var scanDate = observationDate
        while scanDate < nextObservationDate {
            let altitude = sunAltitude(at: scanDate)
            if altitude > maxAltitude {
                maxAltitude = altitude
                anchor = scanDate
            }
            scanDate = scanDate.addingTimeInterval(10 * 60)
        }

        // 2) 極夜: 終日しきい値未満なら 12:00〜翌日 12:00（時計時刻）の 24 時間区間
        guard maxAltitude >= threshold else {
            let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: observationDate)
                ?? observationDate.addingTimeInterval(12 * 60 * 60)
            let nextNoon = calendar.date(byAdding: .day, value: 1, to: noon)
                ?? noon.addingTimeInterval(Constants.secondsPerDay)
            return DateInterval(start: noon, end: nextNoon)
        }

        // 3) 南中から 24 時間、1 分刻みで沈む時刻と次に昇る時刻を探す
        var darkStart: Date?
        for minute in 1...24 * 60 {
            let sampleDate = anchor.addingTimeInterval(Double(minute) * 60)
            let altitude = sunAltitude(at: sampleDate)
            if let darkStart {
                if altitude >= threshold {
                    return DateInterval(start: darkStart, end: sampleDate)
                }
            } else if altitude < threshold {
                darkStart = sampleDate
            }
        }

        // 白夜（沈まない）: nil / 極夜へ移行する日（昇らない）: 探索範囲の終端まで
        guard let darkStart else { return nil }
        return DateInterval(start: darkStart, end: anchor.addingTimeInterval(Constants.secondsPerDay))
    }

    /// 指定日・場所の市民薄明 (太陽高度 -6°) の夜間区間を返す。
    /// 極夜では 24 時間区間、白夜では nil を返す。
    static func civilDarknessInterval(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> DateInterval? {
        darknessInterval(date: date, location: location, timeZone: timeZone, threshold: civilTwilightSunAltitude)
    }

    /// 天気の夜間区間で使う太陽高度のしきい値 (度)。
    /// 通常は市民薄明終了後 (`civilTwilightSunAltitude`) の正時を夜とし、
    /// 白夜などで該当する正時が 1 つもない夜は太陽中心が地平線下 (`horizonSunAltitude`) の正時で代用する。
    static let civilTwilightSunAltitude: Double = -6.0
    static let horizonSunAltitude: Double = 0.0

    /// 指定日・場所で太陽中心が地平線下 (幾何高度 < 0°) にある区間を返す。
    /// 極夜では 24 時間区間、太陽が沈まない日は nil を返す。
    static func sunBelowHorizonInterval(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> DateInterval? {
        darknessInterval(date: date, location: location, timeZone: timeZone, threshold: horizonSunAltitude)
    }

    /// 指定日・場所の日没〜日の出 (太陽中心高度 -0.833°) の区間を返す。
    /// 極夜では 24 時間区間、白夜では nil を返す。
    static func sunsetSunriseInterval(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> DateInterval? {
        darknessInterval(
            date: date,
            location: location,
            timeZone: timeZone,
            threshold: standardSunsetAltitude
        )
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

    /// 日没〜日の出の開始/終了を、観測地タイムゾーンの時計時刻（0..<1440 分）で返す。
    /// 夏時間の切り替え日でも経過秒ではなく実際の時計表示を返す。
    /// 極夜（終日暗い）では日没・日の出が同じ時刻（12:00）になる。
    static func findSunsetSunriseMinutes(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> (sunsetMinutes: Double, sunriseMinutes: Double)? {
        guard let times = findSunsetSunrise(
            date: date,
            location: location,
            timeZone: timeZone
        ) else {
            return nil
        }

        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        func wallClockMinutes(_ date: Date) -> Double {
            let components = calendar.dateComponents([.hour, .minute, .second], from: date)
            return Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
                + Double(components.second ?? 0) / 60
        }
        return (
            sunsetMinutes: wallClockMinutes(times.sunset),
            sunriseMinutes: wallClockMinutes(times.sunrise)
        )
    }

    // 月の赤経・赤緯・位相・地平視差
    // 根拠: Meeus「Astronomical Algorithms」47 章の主要周期項（出差・二均差・年差など）を採用し、
    //       単純な中心差のみのモデルで最大 3° 超あった高度誤差を 0.1° 程度に抑える。
    static func moonRaDec(jd: Double) -> (ra: Double, dec: Double, phase: Double, parallax: Double) {
        let d = jd - AngleMath.j2000JulianDate

        // 月の平均要素
        let L = (218.316 + 13.176396 * d).truncatingRemainder(dividingBy: 360.0)
        let M = AngleMath.toRadians(134.963 + 13.064993 * d)       // 月の平均近点角 M'
        let F = AngleMath.toRadians(93.272 + 13.229350 * d)        // 月の緯度引数
        let D = AngleMath.toRadians(297.850 + 12.190749 * d)       // 月の平均離角
        let Ms = AngleMath.toRadians(357.529 + 0.98560028 * d)     // 太陽の平均近点角

        let longitude = L
            + 6.289 * sin(M)              // 中心差
            + 1.274 * sin(2 * D - M)      // 出差
            + 0.658 * sin(2 * D)          // 二均差
            + 0.214 * sin(2 * M)
            - 0.186 * sin(Ms)             // 年差
            - 0.114 * sin(2 * F)
            + 0.059 * sin(2 * D - 2 * M)
            + 0.057 * sin(2 * D - Ms - M)
            + 0.053 * sin(2 * D + M)
            + 0.046 * sin(2 * D - Ms)
            + 0.041 * sin(M - Ms)
            - 0.035 * sin(D)
            - 0.030 * sin(M + Ms)
        let latitude = 5.128 * sin(F)
            + 0.281 * sin(M + F)
            + 0.278 * sin(M - F)
            + 0.173 * sin(2 * D - F)
            + 0.055 * sin(2 * D - M + F)
            + 0.046 * sin(2 * D - M - F)
            + 0.033 * sin(2 * D + F)

        let lambdaRad = AngleMath.toRadians(longitude)
        let betaRad = AngleMath.toRadians(latitude)

        let epsilonRad = AngleMath.toRadians(23.439)

        let (ra, dec) = eclipticToEquatorial(lambda: lambdaRad, beta: betaRad, epsilon: epsilonRad)

        let sunLambdaRad = sunEclipticLongitude(jd: jd)
        let elongation = AngleMath.normalizedDegrees(AngleMath.toDegrees(lambdaRad) - AngleMath.toDegrees(sunLambdaRad))
        let phase = elongation / 360.0

        // 地平視差 (度)
        let parallax = 0.9508
            + 0.0518 * cos(M)
            + 0.0095 * cos(2 * D - M)
            + 0.0078 * cos(2 * D)
            + 0.0028 * cos(2 * M)

        return (ra, dec, phase, parallax)
    }

    /// 地心高度を観測地から見た高度（視差補正後）へ変換する (度)。
    /// 根拠: 月は地球に近く、視差により最大約 1° 低く見える。
    static func moonTopocentricAltitude(geocentricAltitude: Double, parallax: Double) -> Double {
        let correction = AngleMath.toDegrees(
            asin(sin(AngleMath.toRadians(parallax)) * cos(AngleMath.toRadians(geocentricAltitude)))
        )
        return geocentricAltitude - correction
    }

    /// 月の観測地での高度・方位角・位相をまとめて返す（視差補正込み）。
    static func moonHorizontal(
        jd: Double,
        observer: HorizontalObserver
    ) -> (alt: Double, az: Double, phase: Double) {
        let moon = moonRaDec(jd: jd)
        let (geocentricAltitude, azimuth) = observer.altAz(ra: moon.ra, dec: moon.dec)
        return (
            moonTopocentricAltitude(geocentricAltitude: geocentricAltitude, parallax: moon.parallax),
            azimuth,
            moon.phase
        )
    }

    // MARK: - 月の輝面の向き

    /// 月の輝面（明るい縁の中点）の位置角 χ (度, 0..<360)。天の北極方向を 0° とし東回りに測る。
    /// 根拠: Meeus「Astronomical Algorithms」48 章 式 (48.5)。輝面は月から太陽へ向かう大円の方向を向く。
    static func moonBrightLimbPositionAngle(
        sunRA: Double,
        sunDec: Double,
        moonRA: Double,
        moonDec: Double
    ) -> Double {
        let α0 = AngleMath.toRadians(sunRA)
        let δ0 = AngleMath.toRadians(sunDec)
        let α = AngleMath.toRadians(moonRA)
        let δ = AngleMath.toRadians(moonDec)
        let y = cos(δ0) * sin(α0 - α)
        let x = sin(δ0) * cos(δ) - cos(δ0) * sin(δ) * cos(α0 - α)
        return AngleMath.normalizedDegrees(AngleMath.toDegrees(atan2(y, x)))
    }

    /// 天体の視差角 q (度, -180...180)。天体の位置で天の北極方向から天頂方向までを東回りに測った角度
    /// （南中前は負、南中後は正）。
    /// 根拠: Meeus 14 章 式 (14.1) tan q = sin H / (tan φ cos δ − sin δ cos H) の分子・分母に cos φ を掛けた形
    ///       （極でも tan φ が発散しない）。
    static func parallacticAngle(
        hourAngle: Double,
        declination: Double,
        latitude: Double
    ) -> Double {
        let H = AngleMath.toRadians(hourAngle)
        let δ = AngleMath.toRadians(declination)
        let φ = AngleMath.toRadians(latitude)
        let y = sin(H) * cos(φ)
        let x = sin(φ) * cos(δ) - cos(φ) * sin(δ) * cos(H)
        return AngleMath.toDegrees(atan2(y, x))
    }

    /// 月の輝面の向きを、月の位置での天頂方向を 0° として観測者から見て左回り
    /// （天頂 → 東寄りの側）に測った角度 (度, 0..<360)。χ − q。
    /// 例: 180° は輝面が真下（地平線側）、90° は観測者から見て左側を向く。
    static func moonBrightLimbZenithAngle(
        jd: Double,
        latitude: Double,
        localSiderealTime: Double
    ) -> Double {
        let sun = sunRaDec(jd: jd)
        let moon = moonRaDec(jd: jd)
        let chi = moonBrightLimbPositionAngle(
            sunRA: sun.ra,
            sunDec: sun.dec,
            moonRA: moon.ra,
            moonDec: moon.dec
        )
        let q = parallacticAngle(
            hourAngle: localSiderealTime - moon.ra,
            declination: moon.dec,
            latitude: latitude
        )
        return AngleMath.normalizedDegrees(chi - q)
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
