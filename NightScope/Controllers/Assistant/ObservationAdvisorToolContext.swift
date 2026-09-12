import Foundation
#if DEBUG
import OSLog
#endif

struct ObservationAdvisorToolContext: Equatable, Sendable {
    let language: String
    let upcomingNights: [UpcomingNightToolSnapshot]

#if DEBUG
    private static let logger = Logger(subsystem: "com.nightscope", category: "ObservationAdvisor")
#endif
}

struct ObservationAdvisorPayload: Equatable, Sendable {
    let input: ObservationAdvisorInput
    let toolContext: ObservationAdvisorToolContext
}

struct UpcomingNightToolSnapshot: Equatable, Sendable {
    let dateString: String
    let locationName: String
    let tier: String
}

extension ObservationAdvisorToolContext {
    func groundedAlternatives(from values: [String]?) -> [String] {
        guard let values, !values.isEmpty else { return [] }

        let groundedAlternatives: [String] = upcomingNights.compactMap { candidate in
            let matchesCandidate = values.contains {
                $0.contains(candidate.dateString) && $0.contains(candidate.locationName)
            }
            guard matchesCandidate else { return nil }
            return "\(candidate.dateString) · \(candidate.locationName)"
        }
        .prefix(2)
        .map { $0 }

#if DEBUG
        let excludedCount = values.count - groundedAlternatives.count
        if excludedCount > 0 {
            Self.logger.warning(
                "Grounded alternatives: input=\(values.count, privacy: .public), returned=\(groundedAlternatives.count, privacy: .public), excluded=\(excludedCount, privacy: .public)"
            )
        } else {
            Self.logger.debug(
                "Grounded alternatives: input=\(values.count, privacy: .public), returned=\(groundedAlternatives.count, privacy: .public), excluded=0"
            )
        }
#endif

        return groundedAlternatives
    }
}

enum ObservationAdvisorToolContextBuilder {
    // Source is consumed synchronously on the main actor; the resulting context contains only Sendable values.
    struct Source {
        let upcomingNights: [NightSummary]
        let upcomingIndexes: [Date: StarGazingIndex]
        let locationName: String
        let timeZone: TimeZone
        let localeIdentifier: String
    }

    static func build(source: Source) -> ObservationAdvisorToolContext {
        let locale = Locale(identifier: source.localeIdentifier)
        let language = ObservationAdvisorInputBuilder.supportedAdvisorLanguage(for: locale)
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: source.timeZone)

        let snapshots = source.upcomingNights.compactMap { night -> UpcomingNightToolSnapshot? in
            guard let index = source.upcomingIndexes[calendar.startOfDay(for: night.date)] else {
                return nil
            }

            return UpcomingNightToolSnapshot(
                dateString: DateFormatters.yearMonthDayWeekdayString(
                    from: night.date,
                    timeZone: source.timeZone,
                    locale: locale
                ),
                locationName: ObservationAdvisorInputBuilder.sanitize(source.locationName, language: language),
                tier: ObservationAdvisorInputBuilder.tierLabel(for: index.tier, language: language)
            )
        }

        return ObservationAdvisorToolContext(language: language, upcomingNights: snapshots)
    }
}
