import Foundation

extension MilkyWayCalculator {
    // 高度と空の暗さを組み合わせた観測スコア
    // 高度が高いほど・太陽が地平線から遠いほど高スコア
    static func viewingScore(_ event: AstroEvent) -> Double {
        let darknessBonus = max(0, -event.sunAltitude - 20.0) * 0.5
        return event.galacticCenterAltitude + darknessBonus
    }

    // 可視ウィンドウを検出
    static func findViewingWindows(events: [AstroEvent]) -> [ViewingWindow] {
        var windows: [ViewingWindow] = []
        var windowStart: Date? = nil
        var windowSamples: [AstroEvent] = []

        for event in events {
            if event.galacticCenterVisible {
                if windowStart == nil { windowStart = event.date }
                windowSamples.append(event)
            } else if let start = windowStart {
                if !windowSamples.isEmpty,
                   let bestAlt = windowSamples.max(by: { $0.galacticCenterAltitude < $1.galacticCenterAltitude }),
                   let bestViewing = windowSamples.max(by: { viewingScore($0) < viewingScore($1) }),
                   let lastSample = windowSamples.last {
                    // 各サンプルは sampleIntervalMinutes 分の区間を代表するため、
                    // ウィンドウ終端は最終サンプル時刻 + 1 インターバル。
                    windows.append(ViewingWindow(
                        start: start,
                        end: lastSample.date.addingTimeInterval(Constants.sampleIntervalSeconds),
                        peakTime: bestViewing.date,
                        peakAltitude: bestAlt.galacticCenterAltitude,
                        peakAzimuth: bestViewing.galacticCenterAzimuth
                    ))
                }
                windowStart = nil
                windowSamples = []
            }
        }

        if let start = windowStart,
           !windowSamples.isEmpty,
           let bestAlt = windowSamples.max(by: { $0.galacticCenterAltitude < $1.galacticCenterAltitude }),
           let bestViewing = windowSamples.max(by: { viewingScore($0) < viewingScore($1) }),
           let lastSample = windowSamples.last {
            windows.append(ViewingWindow(
                start: start,
                end: lastSample.date.addingTimeInterval(Constants.sampleIntervalSeconds),
                peakTime: bestViewing.date,
                peakAltitude: bestAlt.galacticCenterAltitude,
                peakAzimuth: bestViewing.galacticCenterAzimuth
            ))
        }

        return mergeNearbyWindows(windows)
    }

    // 近接ウィンドウをマージ (ギャップ ≤ 30分を統合)
    static func mergeNearbyWindows(_ windows: [ViewingWindow], gapThreshold: TimeInterval = Constants.windowMergeGapSeconds) -> [ViewingWindow] {
        guard windows.count > 1 else { return windows }
        var result: [ViewingWindow] = []
        var current = windows[0]
        for next in windows.dropFirst() {
            let gap = next.start.timeIntervalSince(current.end)
            if gap <= gapThreshold {
                let useCurrent = current.peakAltitude >= next.peakAltitude
                current = ViewingWindow(
                    start: current.start,
                    end: next.end,
                    peakTime: useCurrent ? current.peakTime : next.peakTime,
                    peakAltitude: useCurrent ? current.peakAltitude : next.peakAltitude,
                    peakAzimuth: useCurrent ? current.peakAzimuth : next.peakAzimuth
                )
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    // MARK: - Galactic coordinate conversion (Phase 5)

    /// 銀河座標 (l, b) を赤道座標 (RA, Dec) に変換する (J2000.0)。
    /// IAU 1958 定義: 北銀極 RA=192.85948°, Dec=27.12825°,
    /// 銀河赤道の昇交点銀経 l_Ω = 32.93192°
    /// - Parameters:
    ///   - l: 銀経 (度)
    ///   - b: 銀緯 (度)
    /// - Returns: (ra: 度, dec: 度)
    static func galacticToEquatorial(l: Double, b: Double) -> (ra: Double, dec: Double) {
        let lRad   = AngleMath.toRadians(l)
        let bRad   = AngleMath.toRadians(b)
        let raGP   = AngleMath.toRadians(192.85948)  // 北銀極の赤経
        let decGP  = AngleMath.toRadians(27.12825)   // 北銀極の赤緯
        let lOmega = AngleMath.toRadians(32.93192)   // 銀河赤道の昇交点銀経

        let theta = lRad - lOmega

        let sinDec = cos(bRad) * cos(decGP) * sin(theta) + sin(bRad) * sin(decGP)
        let dec = asin(max(-1.0, min(1.0, sinDec)))

        let y =  cos(bRad) * cos(theta)
        let x = -cos(bRad) * sin(decGP) * sin(theta) + sin(bRad) * cos(decGP)
        let ra = AngleMath.normalizedDegrees(AngleMath.toDegrees(raGP + atan2(y, x)))
        return (ra: ra, dec: AngleMath.toDegrees(dec))
    }
}
