import Foundation
import CoreLocation

enum ForecastConfiguration {
    /// 今後の夜間予報として計算する日数。
    static let upcomingNightCount = 9
}

/// 夜間サマリー計算の抽象化。
protocol NightCalculating: Sendable {
    func calculateNightSummary(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) async -> NightSummary
    func calculateUpcomingNights(
        from date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone,
        days: Int
    ) async -> [NightSummary]
}

/// 天文計算をバックグラウンドで実行するサービス。
/// MilkyWayCalculator の static 呼び出しをラップし、
/// AppController がメインスレッドをブロックせずに await できるようにする。
final class NightCalculationService: NightCalculating, Sendable {
    private let summaryCalculator: @Sendable (Date, CLLocationCoordinate2D, TimeZone) -> NightSummary

    /// 計算処理本体を差し替え可能にする。
    init(
        summaryCalculator: @escaping @Sendable (Date, CLLocationCoordinate2D, TimeZone) -> NightSummary = {
            MilkyWayCalculator.calculateNightSummary(date: $0, location: $1, timeZone: $2)
        }
    ) {
        self.summaryCalculator = summaryCalculator
    }

    /// 1 夜分のサマリーを優先度付きで計算する。
    func calculateNightSummary(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) async -> NightSummary {
        let calculator = summaryCalculator
        return await Task(priority: .userInitiated) {
            calculator(date, location, timeZone)
        }.value
    }

    /// 連続する複数日のサマリーを並列化して計算する。
    func calculateUpcomingNights(
        from date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone,
        days: Int = ForecastConfiguration.upcomingNightCount
    ) async -> [NightSummary] {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let observationDate = calendar.startOfDay(for: date)
        return await withTaskGroup(of: (Int, NightSummary).self) { group in
            for offset in 0..<days {
                guard !Task.isCancelled else { break }
                let targetDate = calendar.date(
                    byAdding: .day, value: offset, to: observationDate
                ) ?? observationDate
                group.addTask(priority: .background) { [summaryCalculator] in
                    (offset, summaryCalculator(targetDate, location, timeZone))
                }
            }
            var results: [(Int, NightSummary)] = []
            results.reserveCapacity(days)
            for await result in group {
                results.append(result)
                if Task.isCancelled { group.cancelAll(); break }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
