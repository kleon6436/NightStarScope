import Foundation
import CoreLocation

/// 夜間タイムライン（観測コンディションのサンプル列）を計算するpure struct。
/// I/O なし・@MainActor 不要。
struct StarMapObservationTimeline {

    static func build(
        location: CLLocationCoordinate2D,
        observationDate: Date,
        timeZone: TimeZone,
        nightStartMinutes: Double,
        nightDurationMinutes: Double
    ) -> [StarMapObservationConditionSample] {
        let maximumOffset = StarMapDateLogic.maxSelectableNightOffset(
            nightDurationMinutes: nightDurationMinutes
        )
        guard maximumOffset > 0 else { return [] }

        let stepMinutes = 20.0
        var offsets = Array(stride(from: 0.0, through: maximumOffset, by: stepMinutes))
        if let last = offsets.last, abs(last - maximumOffset) > 0.5 {
            offsets.append(maximumOffset)
        }

        let latRad = location.latitude * .pi / 180
        let cosLat = cos(latRad)
        let sinLat = sin(latRad)

        return offsets.compactMap { offset in
            let realMinutes = StarMapDateLogic.nightOffsetToRealMinutes(
                offset, nightStartMinutes: nightStartMinutes
            )
            guard let date = StarMapDateLogic.date(
                bySettingClockMinutes: realMinutes,
                onObservationDate: observationDate,
                timeZone: timeZone,
                nightStartMinutes: nightStartMinutes
            ) else { return nil }

            let jd  = MilkyWayCalculator.julianDate(from: date)
            let lst = MilkyWayCalculator.localSiderealTime(jd: jd, longitude: location.longitude)
            let sun  = MilkyWayCalculator.sunRaDec(jd: jd)
            let moon = MilkyWayCalculator.moonRaDec(jd: jd)
            let (sunAlt, _)  = MilkyWayCalculator.altAzFast(
                ra: sun.ra,  dec: sun.dec,  cosLat: cosLat, sinLat: sinLat, lst: lst
            )
            let (moonAlt, _) = MilkyWayCalculator.altAzFast(
                ra: moon.ra, dec: moon.dec, cosLat: cosLat, sinLat: sinLat, lst: lst
            )
            return StarMapObservationConditionSample(
                moonAltitude: moonAlt,
                moonPhase: moon.phase,
                sunAltitude: sunAlt
            )
        }
    }
}
