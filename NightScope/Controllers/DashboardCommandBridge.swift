import Foundation

/// Dashboard から選択された地点と日付。
struct DashboardSelection: Equatable {
    let location: FavoriteLocation
    let date: Date
}

/// Dashboard の選択イベントを AppController に伝えるブリッジ。
@MainActor
final class DashboardCommandBridge {
    /// 選択を受け取る処理。AppController が `bindDashboardCommandBridge` で設定する（受け取り手は 1 つ）。
    var selectionHandler: ((DashboardSelection) -> Void)? {
        didSet { assert(oldValue == nil, "selectionHandler の受け取り手は 1 つだけ") }
    }

    init() {}

    /// Dashboard 側の選択を受け取り手へ同期的に渡す。受け取り手がいなければ捨てる。
    func selectFromDashboard(_ selection: DashboardSelection) {
        selectionHandler?(selection)
    }
}
