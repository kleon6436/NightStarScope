#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
struct UpcomingNightsTool: Tool {
    @Generable
    struct Arguments: Sendable {}

    @Generable
    struct Candidate: Equatable, Sendable {
        var date: String
        var locationName: String
        var tier: String
    }

    @Generable
    struct Result: Equatable, Sendable {
        var candidates: [Candidate]
    }

    let snapshots: [UpcomingNightToolSnapshot]

    let name = "upcoming_nights_lookup"
    let description = "Returns only precomputed upcoming night candidates for grounded alternative suggestions."

    init(snapshots: [UpcomingNightToolSnapshot]) {
        self.snapshots = snapshots
    }

    @concurrent
    func call(arguments _: Arguments) async throws -> Result {
        Result(
            candidates: snapshots.map {
                Candidate(
                    date: $0.dateString,
                    locationName: $0.locationName,
                    tier: $0.tier
                )
            }
        )
    }
}
#endif
