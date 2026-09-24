import Foundation
import CoreLocation

extension MilkyWayCalculator {
    // MARK: - Planet Positions (Meeus "Astronomical Algorithms", Table 31.a)

    private struct PlanetOrbit {
        let name: String
        let a: Double         // semi-major axis (AU)
        let e0, eRate: Double // eccentricity = e0 + eRate·T
        let i0, iRate: Double // inclination (deg)
        let Ω0, ΩRate: Double // longitude of ascending node (deg)
        let ω0, ωRate: Double // longitude of perihelion (deg)
        let L0, LRate: Double // mean longitude (deg)
        let H: Double         // absolute magnitude (simplified)
    }

    private static let planetOrbits: [PlanetOrbit] = [
        PlanetOrbit(name: "水星",
            a: 0.38709927, e0: 0.20563593, eRate:  0.00001906,
            i0: 7.00497902, iRate: -0.00594749,
            Ω0: 48.33076593, ΩRate: -0.12534081,
            ω0: 77.45779628, ωRate:  0.16047689,
            L0: 252.25032350, LRate: 149472.67411175, H: -0.42),
        PlanetOrbit(name: "金星",
            a: 0.72333566, e0: 0.00677672, eRate: -0.00004107,
            i0: 3.39467605, iRate: -0.00078890,
            Ω0: 76.67984255, ΩRate: -0.27769418,
            ω0: 131.60246718, ωRate: 0.00268329,
            L0: 181.97909950, LRate: 58517.81538729, H: -4.40),
        PlanetOrbit(name: "火星",
            a: 1.52371034, e0: 0.09339410, eRate:  0.00007882,
            i0: 1.84969142, iRate: -0.00813131,
            Ω0: 49.55953891, ΩRate: -0.29257343,
            ω0: -23.94362959, ωRate: 0.44441088,
            L0: -4.55343205, LRate: 19140.30268499, H: -1.52),
        PlanetOrbit(name: "木星",
            a: 5.20288700, e0: 0.04838624, eRate: -0.00013244,
            i0: 1.30439695, iRate: -0.00183714,
            Ω0: 100.47390909, ΩRate: 0.20469106,
            ω0: 14.72847983, ωRate: 0.21252668,
            L0: 34.39644051, LRate: 3034.74612775, H: -9.40),
        PlanetOrbit(name: "土星",
            a: 9.53667594, e0: 0.05386179, eRate: -0.00013117,
            i0: 2.48599187, iRate:  0.00193609,
            Ω0: 113.66242448, ΩRate: -0.28867794,
            ω0: 92.59887831, ωRate: -0.41897216,
            L0: 49.95424423, LRate: 1222.49362201, H: -8.88),
    ]

    /// 惑星の表示順（planetOrbits の並び順）。
    private static let planetOrder: [String] = planetOrbits.map(\.name)

    /// ケプラー方程式を Newton 法で反復解する (M: 平均近点角 rad, e: 離心率)
    private static func solveKepler(M: Double, e: Double) -> Double {
        var E = M
        for _ in 0..<50 {
            let dE = (M - E + e * sin(E)) / (1.0 - e * cos(E))
            E += dE
            if abs(dE) < 1e-10 { break }
        }
        return E
    }

    /// 地球の日心黄道座標 (AU, 黄道面 = xy 平面)
    private static func earthHelioXY(T: Double) -> (x: Double, y: Double) {
        let e  = 0.01671123 - 0.00004392 * T
        let ωD = AngleMath.normalizedDegrees(102.93768193 + 0.32327364 * T)
        let LD = AngleMath.normalizedDegrees(100.46457166 + 35999.37244981 * T)
        let M  = AngleMath.toRadians(AngleMath.normalizedDegrees(LD - ωD))
        let ω  = AngleMath.toRadians(ωD)
        let E  = solveKepler(M: M, e: e)
        let r  = 1.00000261 * (1.0 - e * cos(E))
        let nu = atan2(sqrt(max(0, 1.0 - e * e)) * sin(E), cos(E) - e)
        let lambda = nu + ω  // 日心黄道経度 (rad)
        return (r * cos(lambda), r * sin(lambda))
    }

    /// 観測地と観測時刻における 5 惑星の地平座標を返す。
    /// - Parameters:
    ///   - jd: ユリウス日
    ///   - latitude: 観測地緯度 (度)
    ///   - lst: 地方恒星時 (度)
    static func planetPositions(jd: Double, latitude: Double, lst: Double) -> [PlanetPosition] {
        let T     = (jd - AngleMath.j2000JulianDate) / 36525.0
        let earth = earthHelioXY(T: T)
        let ε     = AngleMath.toRadians(23.439291 - 0.013004 * T)

        return planetOrbits.compactMap { orbit in
            let e    = orbit.e0 + orbit.eRate * T
            let i    = AngleMath.toRadians(orbit.i0 + orbit.iRate * T)
            let Ω    = AngleMath.toRadians(AngleMath.normalizedDegrees(orbit.Ω0 + orbit.ΩRate * T))
            let ω    = AngleMath.toRadians(AngleMath.normalizedDegrees(orbit.ω0 + orbit.ωRate * T))
            let M    = AngleMath.toRadians(
                AngleMath.normalizedDegrees((orbit.L0 + orbit.LRate * T) - (orbit.ω0 + orbit.ωRate * T))
            )
            let E    = solveKepler(M: M, e: e)
            let r    = orbit.a * (1.0 - e * cos(E))
            let nu   = atan2(sqrt(max(0, 1.0 - e * e)) * sin(E), cos(E) - e)

            // 日心黄道 3D 座標 (Meeus Eq. 33.7)
            let u = nu + (ω - Ω)  // 真近点離角 → 近点黄緯引数
            let X = r * (cos(Ω) * cos(u) - sin(Ω) * sin(u) * cos(i))
            let Y = r * (sin(Ω) * cos(u) + cos(Ω) * sin(u) * cos(i))
            let Z = r * sin(u) * sin(i)

            // 地心黄道座標
            let dx = X - earth.x, dy = Y - earth.y, dz = Z
            let Δ  = sqrt(dx*dx + dy*dy + dz*dz)
            guard Δ > 1e-6 else { return nil }

            let λGeo = atan2(dy, dx)
            let βGeo = atan2(dz, sqrt(dx*dx + dy*dy))

            // 黄道 → 赤道変換
            let (ra, dec) = eclipticToEquatorial(lambda: λGeo, beta: βGeo, epsilon: ε)

            let (alt, az) = altAz(ra: ra, dec: dec, latitude: latitude, lst: lst)

            // 簡易等級 (位相角補正なし。内惑星は過大評価になるが実視に支障はない)
            let mag = min(orbit.H + 5.0 * log10(max(1e-6, r * Δ)), 5.0)
            return PlanetPosition(name: orbit.name, altitude: alt, azimuth: az,
                                  magnitude: mag, geocentricDistAU: Δ)
        }
    }

    // MARK: - Planet Night Summaries

    /// 指定地点・日付における 5 惑星の 1 夜分可視情報を返す。
    /// サンプリング範囲: 当日 18:00 〜 翌日 06:00（現地時刻）、15 分間隔 (49 サンプル)
    static func planetNightSummaries(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> [PlanetNightSummary] {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let startOfDay = calendar.startOfDay(for: date)
        guard
            let nightStart = calendar.date(byAdding: .hour, value: 18, to: startOfDay),
            let nextDay    = calendar.date(byAdding: .day,  value: 1,  to: startOfDay),
            let nightEnd   = calendar.date(byAdding: .hour, value: 6,  to: nextDay)
        else { return [] }

        let intervalSec = Constants.sampleIntervalSeconds
        let sampleCount = Int(nightEnd.timeIntervalSince(nightStart) / intervalSec) + 1

        typealias Sample = (time: Date, alt: Double, az: Double, mag: Double)
        var timeSeries: [String: [Sample]] = [:]

        for i in 0..<sampleCount {
            let t   = nightStart.addingTimeInterval(Double(i) * intervalSec)
            let jd  = julianDate(from: t)
            let lst = localSiderealTime(jd: jd, longitude: location.longitude)
            for pos in planetPositions(jd: jd, latitude: location.latitude, lst: lst) {
                timeSeries[pos.name, default: []].append((t, pos.altitude, pos.azimuth, pos.magnitude))
            }
        }

        return timeSeries.map { name, samples in
            let peakSample  = samples.max(by: { $0.alt < $1.alt })
            let rising      = firstHorizonRising(in: samples)
            let setting     = lastHorizonSetting(in: samples, after: peakSample?.time ?? nightStart)
            let altSamples  = samples.map { AltitudeSample(time: $0.time, altitude: $0.alt) }
            return PlanetNightSummary(
                name: name,
                riseTime:        rising?.time,
                transitTime:     peakSample?.time,
                setTime:         setting?.time,
                peakAltitude:    peakSample?.alt    ?? -90.0,
                magnitude:       peakSample?.mag    ?? 99.0,
                riseAzimuth:     rising?.azimuth,
                transitAzimuth:  peakSample?.az,
                setAzimuth:      setting?.azimuth,
                altitudeSamples: altSamples
            )
        }
        .sorted {
            (planetOrder.firstIndex(of: $0.name) ?? 99) < (planetOrder.firstIndex(of: $1.name) ?? 99)
        }
    }

    /// 方位角の円周補間（0/360° 跨ぎを正しく処理する）。
    static func interpolateAzimuth(_ az0: Double, _ az1: Double, frac: Double) -> Double {
        var delta = az1 - az0
        if delta >  180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return AngleMath.normalizedDegrees(az0 + frac * delta)
    }

    /// 最初の地平線上昇交差点（負→正）の時刻と方位角を線形補間で返す。
    private static func firstHorizonRising(
        in samples: [(time: Date, alt: Double, az: Double, mag: Double)]
    ) -> (time: Date, azimuth: Double)? {
        for i in 1..<samples.count {
            let prev = samples[i - 1], curr = samples[i]
            guard prev.alt < 0, curr.alt >= 0 else { continue }
            let frac = -prev.alt / (curr.alt - prev.alt)
            let time = prev.time.addingTimeInterval(frac * curr.time.timeIntervalSince(prev.time))
            return (time, interpolateAzimuth(prev.az, curr.az, frac: frac))
        }
        return nil
    }

    /// pivot 以降の最後の地平線下降交差点（正→負）の時刻と方位角を線形補間で返す。
    private static func lastHorizonSetting(
        in samples: [(time: Date, alt: Double, az: Double, mag: Double)],
        after pivot: Date
    ) -> (time: Date, azimuth: Double)? {
        var result: (time: Date, azimuth: Double)?
        for i in 1..<samples.count {
            let prev = samples[i - 1], curr = samples[i]
            guard prev.time >= pivot, prev.alt >= 0, curr.alt < 0 else { continue }
            let frac = -prev.alt / (curr.alt - prev.alt)
            let time = prev.time.addingTimeInterval(frac * curr.time.timeIntervalSince(prev.time))
            result = (time, interpolateAzimuth(prev.az, curr.az, frac: frac))
        }
        return result
    }
}
