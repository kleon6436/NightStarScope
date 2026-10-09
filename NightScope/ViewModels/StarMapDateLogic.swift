import Foundation
import CoreLocation

/// 星空マップで使う夜間時刻の変換ロジックをまとめる。
enum StarMapDateLogic {
    /// 夜間スライダー用の夜間範囲。
    /// - Note: `startMinutes` は観測日 0:00 からの時計時刻（分）。夜の開始が深夜 0 時以降
    ///   （高緯度の夏など）の場合は 1440 以上になる。`durationMinutes` も時計時刻の差で表し、
    ///   夏時間の切り替え夜でもスライダー位置と時計時刻の対応がずれないようにする。
    struct NightRange {
        let startMinutes: Double
        let durationMinutes: Double
    }

    /// 日時をタイムゾーン基準の 0-1439 分へ変換する。
    static func clockMinutes(for date: Date, timeZone: TimeZone) -> Double {
        let components = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
            .dateComponents([.hour, .minute], from: date)
        return Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
    }

    /// 観測日 0:00 からの時計時刻（分）を返す。翌日以降の時刻は 1440 以上になる。
    /// 経過秒ではなく暦日差と時計表示から求めるため、夏時間の切り替え日でも時計時刻と一致する。
    static func minutesSinceObservationDay(
        for date: Date,
        observationDate: Date,
        timeZone: TimeZone
    ) -> Double {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let dayOffset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: observationDate),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        return Double(dayOffset * 1_440) + clockMinutes(for: date, timeZone: timeZone)
    }

    /// 夜間開始時刻からのオフセットを、実際の時刻へ戻す。
    static func nightOffsetToRealMinutes(_ offset: Double, nightStartMinutes: Double) -> Double {
        let real = (nightStartMinutes + offset).truncatingRemainder(dividingBy: 1_440)
        return real < 0 ? real + 1_440 : real
    }

    /// 夜間スライダーで選べる最大オフセットを返す。
    static func maxSelectableNightOffset(nightDurationMinutes: Double) -> Double {
        max(0, min(nightDurationMinutes, 1_439))
    }

    /// 実時刻を夜間開始からのオフセットへ正規化する。
    static func realMinutesToNightOffset(
        _ realMinutes: Double,
        nightStartMinutes: Double,
        nightDurationMinutes: Double
    ) -> Double {
        var offset = (realMinutes - nightStartMinutes).truncatingRemainder(dividingBy: 1_440)
        if offset < 0 { offset += 1_440 }
        return max(0, min(maxSelectableNightOffset(nightDurationMinutes: nightDurationMinutes), offset))
    }

    /// 日没・日出から、その日の観測用夜間範囲を算出する。
    static func nightRange(
        for date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone,
        referenceDate: Date? = nil,
        fallback: NightRange
    ) -> NightRange {
        guard let interval = MilkyWayCalculator.sunsetSunriseInterval(
            date: date,
            location: location,
            timeZone: timeZone
        ) else {
            let startMinutes = referenceDate.map { clockMinutes(for: $0, timeZone: timeZone) } ?? fallback.startMinutes
            return NightRange(startMinutes: startMinutes, durationMinutes: 0)
        }

        let startMinutes = minutesSinceObservationDay(
            for: interval.start,
            observationDate: date,
            timeZone: timeZone
        )
        let endMinutes = minutesSinceObservationDay(
            for: interval.end,
            observationDate: date,
            timeZone: timeZone
        )
        let duration = min(1_440, max(0, endMinutes - startMinutes))

        return NightRange(
            startMinutes: startMinutes,
            durationMinutes: duration
        )
    }

    /// 現在時刻が属する観測日（夜の始まる日）の 0:00 を返す。アプリ全体の「今日（今夜）」の定義。
    /// 前日の日没〜当日の日の出の間（深夜〜明け方）なら前日、それ以外は当日の暦日を返す。
    /// - Note: 天体計算（日没・日の出の探索）を伴うため、描画ごとに呼ぶような箇所では結果を使い回す。
    static func currentObservationDate(
        for now: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> Date {
        observationDayBoundaries(containing: now, location: location, timeZone: timeZone)
            .observationDate(for: now)
    }

    /// 暦日 1 日分の観測日判定に必要な夜の境界。同じ暦日・地点なら使い回せる。
    struct ObservationDayBoundaries: Sendable {
        /// 判定対象の暦日の 0:00。
        let today: Date
        /// 前日の 0:00。
        let previousDay: Date
        /// 前日の日没〜当日の日の出。白夜では nil。
        let previousNight: DateInterval?
        /// 当日の日没。白夜では nil。
        let tonightStart: Date?

        /// `now`（`today` の暦日内の時刻）が属する観測日を返す。
        func observationDate(for now: Date) -> Date {
            guard let previousNight,
                  previousNight.start <= now,
                  now < previousNight.end else {
                return today
            }
            // 当日の夜がすでに始まっている場合（極夜など）は当日を優先する。
            if let tonightStart, tonightStart <= now {
                return today
            }
            return previousDay
        }
    }

    /// `now` を含む暦日の観測日判定用の境界を求める。日没・日の出の探索を 2 夜分行う。
    static func observationDayBoundaries(
        containing now: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> ObservationDayBoundaries {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let today = calendar.startOfDay(for: now)
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: today) else {
            return ObservationDayBoundaries(today: today, previousDay: today, previousNight: nil, tonightStart: nil)
        }
        return ObservationDayBoundaries(
            today: today,
            previousDay: previousDay,
            previousNight: MilkyWayCalculator.sunsetSunriseInterval(
                date: previousDay,
                location: location,
                timeZone: timeZone
            ),
            tonightStart: MilkyWayCalculator.sunsetSunriseInterval(
                date: today,
                location: location,
                timeZone: timeZone
            )?.start
        )
    }

    /// 表示用の日付を、観測日に属する実日付へ変換する。
    static func observationDate(
        for presentationDate: Date,
        timeZone: TimeZone,
        nightStartMinutes: Double
    ) -> Date {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let startOfDay = calendar.startOfDay(for: presentationDate)
        let clockMinutes = self.clockMinutes(for: presentationDate, timeZone: timeZone)
        guard clockMinutes < nightStartMinutes else {
            return startOfDay
        }
        return calendar.date(byAdding: .day, value: -1, to: startOfDay) ?? startOfDay
    }

    /// 選択日と参照時刻から、表示に使う日時を解決する。
    /// 参照時刻が夜間（日没〜日の出）に含まれればその時刻を、含まれなければ日没時刻を返す。
    static func resolvedPresentationDate(
        for selectedDate: Date,
        referenceDate: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> Date? {
        guard let interval = MilkyWayCalculator.sunsetSunriseInterval(
            date: selectedDate,
            location: location,
            timeZone: timeZone
        ) else {
            return date(byApplyingTimeOf: referenceDate, to: selectedDate, timeZone: timeZone)
        }

        let nightStartMinutes = minutesSinceObservationDay(
            for: interval.start,
            observationDate: selectedDate,
            timeZone: timeZone
        )
        let referenceMinutes = clockMinutes(for: referenceDate, timeZone: timeZone)
        // 夜の開始 Date を基準に参照時刻を当てはめ、実際の夜間区間に含まれるかで判定する。
        // 極夜（24 時間区間）ではどの時刻も夜間に含まれる。
        if let candidate = date(
            bySettingClockMinutes: referenceMinutes,
            onObservationDate: selectedDate,
            timeZone: timeZone,
            nightStartMinutes: nightStartMinutes
        ), candidate >= interval.start, candidate < interval.end {
            return candidate
        }

        return date(
            bySettingClockMinutes: nightStartMinutes,
            onObservationDate: selectedDate,
            timeZone: timeZone,
            nightStartMinutes: nightStartMinutes
        )
    }

    /// 夜間スライダーの観測日をまたぐ時刻補正を加味して Date を返す。
    /// `nightStartMinutes`（観測日 0:00 からの分, 1440 以上可）以降で最初にその時計時刻となる日時を返す。
    static func date(
        bySettingClockMinutes minutes: Double,
        onObservationDate observationDate: Date,
        timeZone: TimeZone,
        nightStartMinutes: Double
    ) -> Date? {
        let normalizedMinutes = ((Int(minutes.rounded()) % 1_440) + 1_440) % 1_440
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        // 夜の開始が深夜 0 時以降（startMinutes >= 1440）の場合も正しい日付になるよう、
        // 夜の開始以降となる最小の日オフセットを選ぶ（0.5 分は丸め誤差の許容）。
        var dayOffset = 0
        while dayOffset < 2,
              Double(dayOffset * 1_440 + normalizedMinutes) + 0.5 < nightStartMinutes {
            dayOffset += 1
        }
        let baseDate = calendar.date(byAdding: .day, value: dayOffset, to: observationDate) ?? observationDate
        return calendar.date(
            bySettingHour: normalizedMinutes / 60,
            minute: normalizedMinutes % 60,
            second: 0,
            of: baseDate
        )
    }

    private static func date(byApplyingTimeOf referenceDate: Date, to date: Date, timeZone: TimeZone) -> Date? {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let time = calendar.dateComponents([.hour, .minute], from: referenceDate)
        return calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: 0,
            of: date
        )
    }
}
