import Foundation

/// 主要な月相（太陽との黄経の離角が 0/90/180/270° になる瞬間）。
enum PrincipalMoonPhase: CaseIterable, Sendable {
    case new
    case firstQuarter
    case full
    case lastQuarter

    var targetElongationDegrees: Double {
        switch self {
        case .new: return 0
        case .firstQuarter: return 90
        case .full: return 180
        case .lastQuarter: return 270
        }
    }

    var name: String {
        switch self {
        case .new: return L10n.tr("新月")
        case .firstQuarter: return L10n.tr("上弦の月")
        case .full: return L10n.tr("満月")
        case .lastQuarter: return L10n.tr("下弦の月")
        }
    }

    var icon: String {
        switch self {
        case .new: return AppIcons.Astronomy.moonPhaseNew
        case .firstQuarter: return AppIcons.Astronomy.moonPhaseFirstQuarter
        case .full: return AppIcons.Astronomy.moonPhaseFull
        case .lastQuarter: return AppIcons.Astronomy.moonPhaseLastQuarter
        }
    }
}

struct LunarPhaseEvent: Equatable, Sendable {
    let kind: PrincipalMoonPhase
    let date: Date
}

/// 月齢カレンダーの 1 夜分。値はすべて「観測夜」基準（NightSummary と同じ翌 0 時で評価）。
struct LunarDay: Identifiable, Equatable, Sendable {
    /// 観測夜 D（観測地 TZ の 0 時）
    let date: Date
    let phase: Double
    /// 翌 0 時時点での、直前の新月からの経過日数
    let moonAge: Double
    let illumination: Double
    /// 夜 D の窓 [D 12:00, D+1 12:00) に含まれる主要月相
    let principalEvent: LunarPhaseEvent?

    var id: Date { date }
    var isDarkNight: Bool { illumination < MoonPhase.darkIlluminationThreshold }
    var moonlightLevel: MoonPhase.MoonlightLevel { MoonPhase.moonlightLevel(illumination: illumination) }
}

/// 月齢カレンダーの純粋計算（I/O なし・同期）。
enum LunarCalendar {
    /// 簡略化した月の理論式は J2000 から離れるほど誤差が増えるため、表示範囲を制限する。
    static let supportedYears = 1900...2100

    private static let searchStep: TimeInterval = 6 * 3600
    private static let bisectionTolerance: TimeInterval = 60
    /// 表示月の 1 日より前に直前の新月を必ず含めるための探索範囲（朔望月は最長でも約 29.8 日）。
    private static let newMoonLookbackDays = 35
    private static let secondsPerDay: TimeInterval = 86400
    private static let meanSynodicMonthDays = 29.530588

    /// 太陽との黄経の離角（度, 0..<360）。
    static func elongationDegrees(at date: Date) -> Double {
        MilkyWayCalculator.moonRaDec(jd: MilkyWayCalculator.julianDate(from: date)).phase * 360
    }

    /// [start, end) にある主要月相の瞬間を時刻順に返す。
    /// 6 時間刻み（離角は約 3° 進む）で目標角をまたぐ区間を探し、二分法で 1 分精度まで絞る。
    static func phaseEvents(from start: Date, to end: Date) -> [LunarPhaseEvent] {
        guard start < end else { return [] }
        var events: [LunarPhaseEvent] = []
        var lower = start
        var lowerElongation = elongationDegrees(at: lower)
        while lower < end {
            let upper = lower.addingTimeInterval(searchStep)
            let upperElongation = elongationDegrees(at: upper)
            for kind in PrincipalMoonPhase.allCases {
                let target = kind.targetElongationDegrees
                guard signedDifference(lowerElongation, target) < 0,
                      signedDifference(upperElongation, target) >= 0 else { continue }
                let instant = bisect(target: target, lower: lower, upper: upper)
                if instant >= start, instant < end {
                    events.append(LunarPhaseEvent(kind: kind, date: instant))
                }
            }
            lower = upper
            lowerElongation = upperElongation
        }
        return events
    }

    /// 瞬間 `instant` が属する観測夜（観測地 TZ の 0 時）。[D 12:00, D+1 12:00) → D。
    /// 夏時間の日に境界がずれないよう、時間の加減算ではなく時刻の成分で判定する。
    static func night(for instant: Date, timeZone: TimeZone) -> Date {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let day = calendar.startOfDay(for: instant)
        guard calendar.component(.hour, from: instant) < 12 else { return day }
        // 前日の 0 時が存在しない日でも正しく求まるよう、前日内の時刻から startOfDay を取る。
        return calendar.startOfDay(for: day.addingTimeInterval(-1))
    }

    /// `date` を含む月の全日分の LunarDay を返す。
    static func month(containing date: Date, timeZone: TimeZone) -> [LunarDay] {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        guard let monthInterval = calendar.dateInterval(of: .month, for: date),
              let dayCount = calendar.range(of: .day, in: .month, for: date)?.count else { return [] }

        let nights = (0..<dayCount).compactMap { offset -> Date? in
            calendar.date(byAdding: .day, value: offset, to: monthInterval.start).map { calendar.startOfDay(for: $0) }
        }
        let events = phaseEvents(
            from: monthInterval.start.addingTimeInterval(-Double(newMoonLookbackDays) * secondsPerDay),
            to: monthInterval.end.addingTimeInterval(2 * secondsPerDay)
        )
        let newMoons = events.filter { $0.kind == .new }.map(\.date)
        var eventsByNight: [Date: LunarPhaseEvent] = [:]
        for event in events {
            eventsByNight[night(for: event.date, timeZone: timeZone)] = event
        }

        return nights.map { night in
            let midnight = MilkyWayCalculator.nightMidnight(for: night, calendar: calendar)
            let phase = MilkyWayCalculator.moonRaDec(jd: MilkyWayCalculator.julianDate(from: midnight)).phase
            let moonAge = newMoons.last(where: { $0 <= midnight })
                .map { midnight.timeIntervalSince($0) / secondsPerDay }
                ?? phase * meanSynodicMonthDays
            return LunarDay(
                date: night,
                phase: phase,
                moonAge: moonAge,
                illumination: MoonPhase.illumination(phase: phase),
                principalEvent: eventsByNight[night]
            )
        }
    }

    /// 時刻 `date` における月齢（直前の新月からの経過日数）。
    static func moonAge(at date: Date) -> Double {
        let lastNewMoon = phaseEvents(
            from: date.addingTimeInterval(-Double(newMoonLookbackDays) * secondsPerDay),
            to: date.addingTimeInterval(1)
        )
        .last { $0.kind == .new }
        guard let lastNewMoon else {
            return elongationDegrees(at: date) / 360 * meanSynodicMonthDays
        }
        return date.timeIntervalSince(lastNewMoon.date) / secondsPerDay
    }

    /// `value - target` を -180..<180 に正規化した差（度）。
    private static func signedDifference(_ value: Double, _ target: Double) -> Double {
        let difference = (value - target).truncatingRemainder(dividingBy: 360)
        if difference >= 180 { return difference - 360 }
        if difference < -180 { return difference + 360 }
        return difference
    }

    private static func bisect(target: Double, lower: Date, upper: Date) -> Date {
        var lower = lower
        var upper = upper
        while upper.timeIntervalSince(lower) > bisectionTolerance {
            let middle = lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
            if signedDifference(elongationDegrees(at: middle), target) < 0 {
                lower = middle
            } else {
                upper = middle
            }
        }
        return lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
    }
}

extension NightSummary {
    /// 月齢カレンダーと同じ定義の月齢（翌 0 時時点での、直前の新月からの経過日数）。
    var moonAge: Double {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        return LunarCalendar.moonAge(at: MilkyWayCalculator.nightMidnight(for: date, calendar: calendar))
    }

    var moonlightLevel: MoonPhase.MoonlightLevel {
        MoonPhase.moonlightLevel(illumination: moonIllumination)
    }
}
