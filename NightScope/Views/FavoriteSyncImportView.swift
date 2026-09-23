import SwiftUI

/// 取り込み画面の選択状態。既定は未選択で、確定すると選択を空に戻す（二重実行で同じ地点を渡さない）。
struct FavoriteSyncImportSelection: Equatable {
    private(set) var selectedIDs: Set<UUID> = []

    func isSelected(_ location: FavoriteLocation) -> Bool {
        selectedIDs.contains(location.id)
    }

    func isAllSelected(in candidates: [FavoriteLocation]) -> Bool {
        !candidates.isEmpty && candidates.allSatisfy(isSelected)
    }

    mutating func toggle(_ location: FavoriteLocation) {
        if selectedIDs.remove(location.id) == nil {
            selectedIDs.insert(location.id)
        }
    }

    mutating func selectAll(in candidates: [FavoriteLocation]) {
        selectedIDs = Set(candidates.map(\.id))
    }

    mutating func deselectAll() {
        selectedIDs = []
    }

    /// 一覧から消えた地点の選択を外す。
    mutating func prune(to candidates: [FavoriteLocation]) {
        selectedIDs.formIntersection(candidates.map(\.id))
    }

    /// 選択中の地点を一覧の順で `perform` に渡し、選択を空に戻す。選択がなければ `perform` を呼ばずに 0 を返す。
    mutating func commit(from candidates: [FavoriteLocation], perform: ([FavoriteLocation]) -> Int) -> Int {
        let selected = candidates.filter(isSelected)
        selectedIDs = []
        guard !selected.isEmpty else { return 0 }
        return perform(selected)
    }
}

/// iCloud とこの端末の差分から、ユーザーが選んだ地点だけを取り込むシート。
struct FavoriteSyncImportView: View {
    @ObservedObject var reconciler: FavoriteSyncReconciler
    @Environment(\.dismiss) private var dismiss
    @State private var selection = FavoriteSyncImportSelection()
    @State private var resultMessage: String?

    #if os(macOS)
    private static let sheetMinWidth: CGFloat = 420
    private static let sheetMinHeight: CGFloat = 360
    #endif
    /// [すべて選択] 行のタップ領域の最小の高さ。
    private static let minimumTapHeight: CGFloat = 44

    private var candidates: [FavoriteLocation] {
        reconciler.activeMode == .icloud ? reconciler.localOnly : reconciler.cloudOnly
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if !candidates.isEmpty {
                    candidatesSection
                    actionSection
                } else if resultMessage == nil {
                    Text("取り込める地点はありません")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("地点の取り込み")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: Self.sheetMinWidth, minHeight: Self.sheetMinHeight)
        #endif
        .onAppear {
            reconciler.refresh()
        }
        .onChange(of: candidates) { _, newValue in
            selection.prune(to: newValue)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if reconciler.isPendingRestart {
            Section {
                Label("再起動後に反映されます", systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(.secondary)
            }
        } else if let resultMessage {
            Section {
                Label {
                    Text(resultMessage)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var candidatesSection: some View {
        Section {
            selectAllButton
            ForEach(candidates) { location in
                FavoriteSyncImportRow(
                    location: location,
                    isSelected: selection.isSelected(location),
                    onToggle: { selection.toggle(location) }
                )
            }
        } header: {
            Text(listTitle)
        }
        .disabled(reconciler.isPendingRestart)
    }

    /// 全件選択中は「選択を解除」に切り替わる。
    private var selectAllButton: some View {
        let isAllSelected = selection.isAllSelected(in: candidates)
        return Button {
            if isAllSelected {
                selection.deselectAll()
            } else {
                selection.selectAll(in: candidates)
            }
        } label: {
            Text(isAllSelected ? L10n.tr("選択を解除") : L10n.tr("すべて選択"))
                .frame(maxWidth: .infinity, minHeight: Self.minimumTapHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private var actionSection: some View {
        Section {
            Button(action: performImport) {
                Text(actionTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.selectedIDs.isEmpty || reconciler.isPendingRestart)
        }
    }

    private var listTitle: String {
        reconciler.activeMode == .icloud ? L10n.tr("この端末にのみある地点") : L10n.tr("iCloud にのみある地点")
    }

    private var actionTitle: String {
        reconciler.activeMode == .icloud
            ? L10n.tr("選択した地点を iCloud に追加")
            : L10n.tr("選択した地点をこの端末に取り込む")
    }

    private func performImport() {
        guard !reconciler.isPendingRestart else { return }
        let mode = reconciler.activeMode
        let added = selection.commit(from: candidates) { selected in
            mode == .icloud ? reconciler.addToCloud(selected) : reconciler.importToLocal(selected)
        }
        // 選択が空のときや二重に発火したときは 0 件になるので、直前の結果表示を残す。
        guard added > 0 else { return }
        resultMessage = mode == .icloud
            ? L10n.format("iCloud に %d 件追加しました", added)
            : L10n.format("この端末に %d 件取り込みました", added)
    }
}

/// 取り込み候補の1行。行全体をタップすると選択を切り替える。
private struct FavoriteSyncImportRow: View {
    let location: FavoriteLocation
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.name)
                        .foregroundStyle(.primary)
                    Text(L10n.format("%.4f, %.4f", location.latitude, location.longitude))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// iCloud モードで、この端末にのみある地点の件数を知らせるバナー。
/// 表示条件は `reconciler.isLocalOnlyBannerVisible`。お気に入りが空のときは強調表示にする。
struct FavoriteSyncLocalOnlyBanner: View {
    @ObservedObject var reconciler: FavoriteSyncReconciler
    let isEmphasized: Bool
    let onReview: () -> Void

    private static let tintOpacity: Double = 0.12
    private static let strokeOpacity: Double = 0.28
    private static let strokeWidth: CGFloat = 1

    var body: some View {
        if reconciler.isLocalOnlyBannerVisible {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label {
                    Text(L10n.format("この端末にのみある地点が %d 件あります", reconciler.localOnly.count))
                        .font(.callout)
                        .fontWeight(isEmphasized ? .semibold : .regular)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "icloud.and.arrow.up")
                        .foregroundStyle(isEmphasized ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }

                HStack(spacing: Spacing.xs) {
                    Spacer(minLength: 0)
                    Button("あとで") {
                        reconciler.dismissLocalOnlyBanner()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint(L10n.tr("件数が変わるまでこのお知らせを表示しません"))
                    Button("確認", action: onReview)
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint(L10n.tr("取り込む地点を選ぶ画面を開きます"))
                }
                #if os(macOS)
                .controlSize(.small)
                #endif
            }
            .padding(Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Layout.smallCornerRadius, style: .continuous)
        if isEmphasized {
            shape
                .fill(Color.accentColor.opacity(Self.tintOpacity))
                .overlay(shape.stroke(Color.accentColor.opacity(Self.strokeOpacity), lineWidth: Self.strokeWidth))
        } else {
            shape.fill(.fill.tertiary)
        }
    }
}

#if DEBUG
/// プレビュー専用の KV ストア。本物の iCloud KVS には触れない。
private final class PreviewKeyValueStore: UbiquitousKeyValueStoring {
    private var values: [String: Data] = [:]

    func data(forKey aKey: String) -> Data? {
        values[aKey]
    }

    func set(_ aData: Data?, forKey aKey: String) {
        values[aKey] = aData
    }

    func synchronize() -> Bool {
        true
    }
}

/// プレビュー用の reconciler を、専用 suite の UserDefaults とフェイクの KV で組み立てる（`.standard` には触れない）。
@MainActor
private enum FavoriteSyncPreviewSupport {
    static let tokyo = FavoriteLocation(name: "東京", latitude: 35.6812, longitude: 139.7671, timeZoneIdentifier: "Asia/Tokyo")
    static let nagano = FavoriteLocation(name: "長野", latitude: 36.6486, longitude: 138.1948, timeZoneIdentifier: "Asia/Tokyo")
    static let ishigaki = FavoriteLocation(name: "石垣島", latitude: 24.3448, longitude: 124.1572, timeZoneIdentifier: "Asia/Tokyo")

    /// 稼働中のストアは常に iCloud。`iCloudSyncEnabled` を false にすると再起動待ちの状態になる。
    static func makeICloudReconciler(
        suffix: String,
        kv: [FavoriteLocation],
        local: [FavoriteLocation],
        iCloudSyncEnabled: Bool = true
    ) -> FavoriteSyncReconciler {
        let suiteName = "FavoriteSyncImportView.preview.\(suffix)"
        UserDefaults().removePersistentDomain(forName: suiteName)
        // suite 名がアプリの bundle ID や NSGlobalDomain でない限り nil にはならない。
        let defaults = UserDefaults(suiteName: suiteName)!
        FavoriteLocationStore(userDefaults: defaults).save(local)
        defaults.set(iCloudSyncEnabled, forKey: "iCloudSyncEnabled")
        let kvStore = PreviewKeyValueStore()
        kvStore.set(try? JSONEncoder().encode(kv), forKey: iCloudFavoriteLocationStore.iCloudKey)
        let store = iCloudFavoriteLocationStore(
            kvStore: kvStore,
            fallbackDefaults: defaults,
            notificationCenter: NotificationCenter()
        )
        return FavoriteSyncReconciler(
            activeStore: store,
            localDefaults: defaults,
            kvStore: kvStore,
            toggleProvider: { defaults.bool(forKey: "iCloudSyncEnabled") }
        )
    }
}

#Preview("iCloud モード・候補2件") {
    FavoriteSyncImportView(
        reconciler: FavoriteSyncPreviewSupport.makeICloudReconciler(
            suffix: "candidates",
            kv: [FavoriteSyncPreviewSupport.tokyo],
            local: [FavoriteSyncPreviewSupport.nagano, FavoriteSyncPreviewSupport.ishigaki]
        )
    )
}

#Preview("再起動待ち") {
    FavoriteSyncImportView(
        reconciler: FavoriteSyncPreviewSupport.makeICloudReconciler(
            suffix: "pending",
            kv: [FavoriteSyncPreviewSupport.tokyo],
            local: [FavoriteSyncPreviewSupport.nagano, FavoriteSyncPreviewSupport.ishigaki],
            iCloudSyncEnabled: false
        )
    )
}

#Preview("強調表示のバナー") {
    FavoriteSyncLocalOnlyBanner(
        reconciler: FavoriteSyncPreviewSupport.makeICloudReconciler(
            suffix: "banner",
            kv: [],
            local: [FavoriteSyncPreviewSupport.nagano, FavoriteSyncPreviewSupport.ishigaki]
        ),
        isEmphasized: true,
        onReview: {}
    )
    .padding()
    .frame(width: 320)
}
#endif
