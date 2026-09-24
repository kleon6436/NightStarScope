import SwiftUI

/// 星図描画に必要な天体位置をまとめて計算するユーティリティ。
enum StarMapComputation {
    /// 1 回の描画に必要な計算結果のスナップショット。
    struct Snapshot: Sendable {
        let starPositions: [StarPosition]
        let sunAltitude: Double
        let moonAltitude: Double
        let moonAzimuth: Double
        let moonPhase: Double
        let galacticCenterAltitude: Double
        let galacticCenterAzimuth: Double
        let constellationLines: [ConstellationLineAltAz]
        let constellationLabels: [ConstellationLabelAltAz]
        let planetPositions: [PlanetPosition]
        let meteorShowerRadiants: [(shower: MeteorShower, altitude: Double, azimuth: Double)]
        let milkyWayBandPoints: [MilkyWayBandPoint]
    }

    private static let cachedStarColors: [Color] = {
        StarCatalog.stars.map { starColorForBV($0.colorIndex) }
    }()

    static func compute(
        latitude: Double,
        longitude: Double,
        julianDate: Double,
        localSiderealTime: Double,
        activeMeteorShowers: [MeteorShower],
        starDisplayDensity: StarDisplayDensity
    ) -> Snapshot {
        let latRad = latitude * .pi / 180.0
        let observer = MilkyWayCalculator.HorizontalObserver(
            cosLat: cos(latRad),
            sinLat: sin(latRad),
            lst: localSiderealTime
        )

        let catalog = StarCatalog.stars
        let magnitudeLimit = starDisplayDensity.maxMagnitude
        var stars = [StarPosition]()
        stars.reserveCapacity(catalog.count / 2)

        for index in catalog.indices {
            let star = catalog[index]
            // 表示密度と地平線下のカットオフを満たす星だけを残す。
            guard star.magnitude <= magnitudeLimit else { continue }
            let (altitude, azimuth) = observer.altAz(ra: star.ra, dec: star.dec)
            guard altitude > -3 else { continue }
            stars.append(
                StarPosition(
                    star: star,
                    altitude: altitude,
                    azimuth: azimuth,
                    precomputedColor: cachedStarColors[index]
                )
            )
        }

        let sun = MilkyWayCalculator.sunRaDec(jd: julianDate)
        let (sunAltitude, _) = observer.altAz(ra: sun.ra, dec: sun.dec)

        let moon = MilkyWayCalculator.moonRaDec(jd: julianDate)
        let (moonAltitude, moonAzimuth) = observer.altAz(ra: moon.ra, dec: moon.dec)

        let (galacticCenterAltitude, galacticCenterAzimuth) = observer.altAz(
            ra: MilkyWayCalculator.gcRA,
            dec: MilkyWayCalculator.gcDec
        )

        let constellationLines: [ConstellationLineAltAz] = ConstellationData.constellations.flatMap { entry in
            entry.segments.compactMap { segment in
                let (startAltitude, startAzimuth) = observer.altAz(ra: segment.ra1, dec: segment.dec1)
                let (endAltitude, endAzimuth) = observer.altAz(ra: segment.ra2, dec: segment.dec2)
                guard startAltitude > -15 || endAltitude > -15 else { return nil }
                return ConstellationLineAltAz(
                    startAlt: startAltitude,
                    startAz: startAzimuth,
                    endAlt: endAltitude,
                    endAz: endAzimuth
                )
            }
        }

        let constellationLabels: [ConstellationLabelAltAz] = ConstellationData.constellations.compactMap { entry in
            let (altitude, azimuth) = observer.altAz(ra: entry.centerRA, dec: entry.centerDec)
            guard altitude > -5 else { return nil }
            return ConstellationLabelAltAz(alt: altitude, az: azimuth, name: entry.localizedName)
        }

        let meteorRadiants = activeMeteorShowers.map { shower in
            let (altitude, azimuth) = observer.altAz(ra: shower.radiantRA, dec: shower.radiantDec)
            return (shower: shower, altitude: altitude, azimuth: azimuth)
        }

        return Snapshot(
            starPositions: stars,
            sunAltitude: sunAltitude,
            moonAltitude: moonAltitude,
            moonAzimuth: moonAzimuth,
            moonPhase: moon.phase,
            galacticCenterAltitude: galacticCenterAltitude,
            galacticCenterAzimuth: galacticCenterAzimuth,
            constellationLines: constellationLines,
            constellationLabels: constellationLabels,
            planetPositions: MilkyWayCalculator.planetPositions(
                jd: julianDate,
                latitude: latitude,
                lst: localSiderealTime
            ),
            meteorShowerRadiants: meteorRadiants,
            milkyWayBandPoints: computeMilkyWayBandPoints(observer: observer)
        )
    }

    private static func computeMilkyWayBandPoints(
        observer: MilkyWayCalculator.HorizontalObserver
    ) -> [MilkyWayBandPoint] {
        var result = [MilkyWayBandPoint]()
        let step: Double = 5

        for longitude in stride(from: 0.0, to: 360.0, by: step) {
            // 銀河面が十分に見える区間だけを点列として残す。
            let equatorialCenter = MilkyWayCalculator.galacticToEquatorial(l: longitude, b: 0)
            let (altitudeCenter, azimuthCenter) = observer.altAz(ra: equatorialCenter.ra, dec: equatorialCenter.dec)
            guard altitudeCenter > -5 else { continue }

            let bandWidth: Double = longitude > 270 || longitude < 90 ? 12 : 8
            let upper = MilkyWayCalculator.galacticToEquatorial(l: longitude, b: bandWidth)
            let lower = MilkyWayCalculator.galacticToEquatorial(l: longitude, b: -bandWidth)
            let (upperAltitude, _) = observer.altAz(ra: upper.ra, dec: upper.dec)
            let (lowerAltitude, _) = observer.altAz(ra: lower.ra, dec: lower.dec)

            result.append(
                MilkyWayBandPoint(
                    az: azimuthCenter,
                    alt: altitudeCenter,
                    halfH: max(3.0, abs(upperAltitude - lowerAltitude) / 2),
                    li: longitude
                )
            )
        }

        return result
    }
}
