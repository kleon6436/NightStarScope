import Foundation
import Observation

/// 月齢カレンダー画面の表示月・選択夜・月相データを管理する ViewModel。
@MainActor
@Observable
final class LunarCalendarViewModel {
    /// 表示中の月（観測地 TZ の、その月内の任意の日の 0 時）
    private(set) var displayMonth: Date
    /// 日曜始まりのグリッド用。先頭の空セルは nil。
    private(set) var days: [LunarDay?] = []
    private(set) var selectedNight: Date
    private(set) var isSouthernHemisphere: Bool
    private(set) var timeZone: TimeZone

    @ObservationIgnored private let currentObservationDate: () -> Date
    @ObservationIgnored private let onOpenNight: (Date) -> Void
    @ObservationIgnored private var locationObservationTask: Task<Void, Never>?

    /// - Parameters:
    ///   - currentObservationDate: 「今日」とみなす観測夜を返す。
    ///   - onOpenNight: 「この夜の空模様を見る」で選んだ夜を受け取る。
    convenience init(
        location: any LocationProviding,
        currentObservationDate: @escaping () -> Date,
        onOpenNight: @escaping (Date) -> Void
    ) {
        self.init(
            latitude: location.selectedLocation.latitude,
            timeZone: location.selectedTimeZone,
            currentObservationDate: currentObservationDate,
            onOpenNight: onOpenNight
        )
        observeLocation(location)
    }

    init(
        latitude: Double,
        timeZone: TimeZone,
        currentObservationDate: @escaping () -> Date,
        onOpenNight: @escaping (Date) -> Void = { _ in }
    ) {
        self.currentObservationDate = currentObservationDate
        self.onOpenNight = onOpenNight
        let today = ObservationTimeZone.startOfDay(for: currentObservationDate(), timeZone: timeZone)
        self.timeZone = timeZone
        self.displayMonth = today
        self.selectedNight = today
        self.isSouthernHemisphere = latitude < 0
        recompute()
    }

    deinit {
        locationObservationTask?.cancel()
    }

    /// 観測地の半球とタイムゾーンに追従する。
    /// Observations は購読開始時の値も流すが、現在の値と同じなら何もしない（旧 removeDuplicates と同じ扱い）。
    private func observeLocation(_ location: any LocationProviding) {
        let changes = Observations { (location.selectedLocation.latitude < 0, location.selectedTimeZone) }
        locationObservationTask = Task { [weak self] in
            for await (isSouthernHemisphere, timeZone) in changes {
                guard let self else { return }
                if self.isSouthernHemisphere != isSouthernHemisphere {
                    self.isSouthernHemisphere = isSouthernHemisphere
                }
                self.updateTimeZone(timeZone)
            }
        }
    }

    private var calendar: Calendar {
        ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
    }

    var today: Date {
        ObservationTimeZone.startOfDay(for: currentObservationDate(), timeZone: timeZone)
    }

    var selectedDay: LunarDay? {
        days.lazy.compactMap { $0 }.first { $0.date == self.selectedNight }
    }

    /// 表示月の各夜に割り当てられた主要月相（時刻順）。
    var phaseEvents: [LunarPhaseEvent] {
        days.compactMap { $0?.principalEvent }
    }

    var canShiftBackward: Bool { shiftedMonth(by: -1) != nil }
    var canShiftForward: Bool { shiftedMonth(by: 1) != nil }

    func shiftMonth(by value: Int) {
        guard let month = shiftedMonth(by: value) else { return }
        displayMonth = month
        recompute()
        // 詳細パネルが消えないよう、選択も新しい月の同じ日（なければ月末）へ移す。
        let dayOfMonth = calendar.component(.day, from: selectedNight)
        let monthDays = days.compactMap { $0 }
        if let night = monthDays.first(where: { calendar.component(.day, from: $0.date) == dayOfMonth }) ?? monthDays.last {
            selectedNight = night.date
        }
    }

    func goToToday() {
        let today = today
        selectedNight = today
        if !calendar.isDate(today, equalTo: displayMonth, toGranularity: .month) {
            displayMonth = today
            recompute()
        }
    }

    func select(_ night: Date) {
        selectedNight = calendar.startOfDay(for: night)
    }

    func openNight(_ night: Date) {
        select(night)
        onOpenNight(selectedNight)
    }

    private func shiftedMonth(by value: Int) -> Date? {
        guard let month = calendar.date(byAdding: .month, value: value, to: displayMonth),
              LunarCalendar.supportedYears.contains(calendar.component(.year, from: month)) else { return nil }
        return calendar.startOfDay(for: month)
    }

    private func updateTimeZone(_ newTimeZone: TimeZone) {
        guard newTimeZone != timeZone else { return }
        let oldTimeZone = timeZone
        displayMonth = ObservationTimeZone.preservingCalendarDay(displayMonth, from: oldTimeZone, to: newTimeZone)
        selectedNight = ObservationTimeZone.preservingCalendarDay(selectedNight, from: oldTimeZone, to: newTimeZone)
        timeZone = newTimeZone
        recompute()
    }

    private func recompute() {
        let monthDays = LunarCalendar.month(containing: displayMonth, timeZone: timeZone)
        guard let first = monthDays.first else {
            days = []
            return
        }
        let leadingBlankCount = calendar.component(.weekday, from: first.date) - 1  // 1=日
        days = Array(repeating: nil, count: leadingBlankCount) + monthDays.map(Optional.some)
    }
}
