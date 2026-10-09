import SwiftUI

/// アプリ全体の表示設定とデータソース情報をまとめる設定画面。
/// - Note: プラットフォーム固有のセクション（iOS のコンパスなど）は、各ターゲットの呼び出し側から `platformSections` で渡す。
struct SettingsView<PlatformSections: View>: View {
    @AppStorage("windSpeedUnit") private var windSpeedUnit: String = WindSpeedUnit.kmh.rawValue
    @AppStorage(AppSettingsKeys.iCloudSyncEnabled) private var iCloudSyncEnabled: Bool = false
    @ObservedObject private var observationModePreference: ObservationModePreference
    private let favoriteSyncReconciler: FavoriteSyncReconciler?
    private let platformSections: PlatformSections
    @State private var isFavoriteImportPresented = false

    init(
        observationModePreference: ObservationModePreference = ObservationModePreference(),
        favoriteSyncReconciler: FavoriteSyncReconciler? = nil,
        @ViewBuilder platformSections: () -> PlatformSections
    ) {
        self.observationModePreference = observationModePreference
        self.favoriteSyncReconciler = favoriteSyncReconciler
        self.platformSections = platformSections()
    }

    var body: some View {
        formContent
            .navigationTitle("設定")
            .inlineNavigationTitleDisplay()
    }

    private var formContent: some View {
        Form {
            Section("iCloud 同期") {
                Toggle("お気に入り地点を同期する", isOn: $iCloudSyncEnabled)
                if iCloudSyncEnabled {
                    Text("macOS・iPhone でお気に入りが共有されます。変更は次回起動後に反映されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let favoriteSyncReconciler {
                    FavoriteSyncSettingsRows(reconciler: favoriteSyncReconciler) {
                        isFavoriteImportPresented = true
                    }
                }
            }

            Section("天気表示") {
                Picker("風速単位", selection: $windSpeedUnit) {
                    ForEach(WindSpeedUnit.allCases) { unit in
                        Text(unit.label).tag(unit.rawValue)
                    }
                }
            }

            #if os(macOS)
            Section("観測モード") {
                Picker("モード", selection: $observationModePreference.mode) {
                    ForEach(ObservationMode.allCases) { mode in
                        Label(L10n.tr(mode.titleKey), systemImage: mode.iconSystemName)
                            .tag(mode)
                    }
                }

                Text(L10n.tr(observationModePreference.mode.descriptionKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif

            StarMapDisplaySettingsSection()

            platformSections

            #if os(iOS)
            Section("情報") {
                NavigationLink {
                    SettingsAboutView()
                } label: {
                    Label("データソースとクレジット", systemImage: "info.circle")
                }
            }
            #else
            SettingsAboutSections()
            #endif
        }
        .formStyle(.grouped)
        .onAppear {
            favoriteSyncReconciler?.refresh()
        }
        .sheet(isPresented: $isFavoriteImportPresented) {
            if let favoriteSyncReconciler {
                FavoriteSyncImportView(reconciler: favoriteSyncReconciler)
            }
        }
        #if os(macOS)
        .frame(width: 420, alignment: .top)
        .padding(.vertical, Spacing.sm)
        #endif
    }

}

extension SettingsView where PlatformSections == EmptyView {
    init(
        observationModePreference: ObservationModePreference = ObservationModePreference(),
        favoriteSyncReconciler: FavoriteSyncReconciler? = nil
    ) {
        self.init(
            observationModePreference: observationModePreference,
            favoriteSyncReconciler: favoriteSyncReconciler,
            platformSections: { EmptyView() }
        )
    }
}

/// iCloud 同期セクションの差分件数と、選んで追加・取り込む導線。一覧が0件のときは出さない。
/// iCloud モードでは、自動追加されなかった地点（v1 からの残りや、古い一覧の保存で iCloud から消えた地点など）の安全網になる。
private struct FavoriteSyncSettingsRows: View {
    @ObservedObject var reconciler: FavoriteSyncReconciler
    let onReview: () -> Void

    private var count: Int {
        reconciler.activeMode == .icloud ? reconciler.localOnly.count : reconciler.cloudOnly.count
    }

    private var title: String {
        reconciler.activeMode == .icloud ? L10n.tr("この端末にのみある地点") : L10n.tr("iCloud にのみある地点")
    }

    var body: some View {
        if count > 0 {
            LabeledContent(title) {
                Text(L10n.format("%d 件", count))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button(action: onReview) {
                if reconciler.activeMode == .icloud {
                    Label("確認して追加", systemImage: "icloud.and.arrow.up")
                } else {
                    Label("確認して取り込む", systemImage: "square.and.arrow.down.on.square")
                }
            }
        }
    }
}

private struct SettingsAboutView: View {
    var body: some View {
        Form {
            SettingsAboutSections()
        }
        .formStyle(.grouped)
        .navigationTitle("アプリ情報")
    }
}

/// 帰属表示とバージョン情報をまとめた補助セクション。
private struct SettingsAboutSections: View {
    private var dataSources: [SettingsDataSource] {
        [
            SettingsDataSource(
                id: "weather",
                title: "天気予報",
                detail: "Apple WeatherKit を使用します。",
                license: nil,
                note: "ネットワーク接続が必要です。",
                attribution: nil,
                links: [],
                showsWeatherBadge: true
            ),
            SettingsDataSource(
                id: "light-pollution",
                title: "光害マップ",
                detail: "Falchi et al. 2016 – World Atlas of Artificial Night Sky Brightness (GFZ Data Services)",
                license: "CC BY 4.0",
                note: "バンドル済みデータを優先して利用します。",
                attribution: "Contains modified World Atlas of Artificial Night Sky Brightness data © Falchi et al. 2016, GFZ Data Services (DOI: 10.5880/GFZ.1.4.2016.001), licensed under CC BY 4.0.",
                links: [
                    SettingsDataSourceLink(title: "Falchi DOI", destination: SettingsAboutLinks.falchiDOI),
                    SettingsDataSourceLink(title: "CC BY 4.0", destination: SettingsAboutLinks.ccBy40),
                ],
                showsWeatherBadge: false
            ),
            SettingsDataSource(
                id: "terrain",
                title: "地形データ",
                detail: "Copernicus DEM GLO-30 © DLR/ESA",
                license: "Copernicus DEM GLO-30 License",
                note: "未配置の場合は一部表示・計算が簡略化されます。",
                attribution: "produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved.",
                links: [
                    SettingsDataSourceLink(title: "Copernicus DEM データ概要", destination: SettingsAboutLinks.copernicusLicense),
                    SettingsDataSourceLink(title: "Copernicus DEM ライセンス", destination: SettingsAboutLinks.copernicusLicensePDF),
                ],
                showsWeatherBadge: false
            ),
            SettingsDataSource(
                id: "star-catalog",
                title: "星カタログ",
                detail: "HYG Database v4.1 / David Nash (astronexus)",
                license: "CC BY-SA 4.0",
                note: nil,
                attribution: "Star data derived from the HYG Database v4.1 by David Nash (https://github.com/astronexus/HYG-Database), licensed under CC BY-SA 4.0. The bundled star list is a derivative work distributed under the same license.",
                links: [
                    SettingsDataSourceLink(title: "HYG Database (GitHub)", destination: SettingsAboutLinks.hygDatabase),
                    SettingsDataSourceLink(title: "CC BY-SA 4.0", destination: SettingsAboutLinks.ccBySa40),
                ],
                showsWeatherBadge: false
            ),
            SettingsDataSource(
                id: "constellation-lines",
                title: "星座線データ",
                detail: "d3-celestial constellation data / Olaf Frohn",
                license: "BSD 3-Clause",
                note: nil,
                attribution: "BSD 3-Clause notice: Copyright (c) Olaf Frohn. Redistribution and use in source and binary forms, with or without modification, are permitted provided that the copyright notice, license conditions, and disclaimer are retained. Provided \"as is\" without warranties.",
                links: [
                    SettingsDataSourceLink(title: "d3-celestial LICENSE", destination: SettingsAboutLinks.d3CelestialLicense),
                ],
                showsWeatherBadge: false
            ),
        ]
    }

    var body: some View {
        Section("データソースとクレジット") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(dataSources) { dataSource in
                    DataSourceRow(dataSource: dataSource)
                }
            }
            .padding(.vertical, 4)
        }

        Section("アプリ情報") {
            LabeledContent("バージョン") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("ビルド") {
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum SettingsAboutLinks {
    static let falchiDOI = URL(string: "https://doi.org/10.5880/GFZ.1.4.2016.001")!
    static let ccBy40 = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    static let copernicusLicense = URL(string: "https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM")!
    static let copernicusLicensePDF = URL(string: "https://documentation.dataspace.copernicus.eu/APIs/SentinelHub/Data/DEM/resources/license/License-COPDEM-30.pdf")!
    static let hygDatabase = URL(string: "https://github.com/astronexus/HYG-Database")!
    static let ccBySa40 = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!
    static let d3CelestialLicense = URL(string: "https://github.com/ofrohn/d3-celestial/blob/master/LICENSE")!
}

private struct SettingsDataSource: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let license: LocalizedStringKey?
    let note: LocalizedStringKey?
    let attribution: String?
    let links: [SettingsDataSourceLink]
    let showsWeatherBadge: Bool
}

private struct SettingsDataSourceLink: Identifiable {
    let title: LocalizedStringKey
    let destination: URL

    var id: String {
        destination.absoluteString
    }
}

private struct DataSourceRow: View {
    let dataSource: SettingsDataSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dataSource.title)
                .font(.subheadline)
                .fontWeight(.medium)
            if dataSource.showsWeatherBadge {
                WeatherAttributionBadge(style: .full)
            }
            Text(dataSource.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let license = dataSource.license {
                Text(license)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let note = dataSource.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let attribution = dataSource.attribution {
                Text(verbatim: attribution)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !dataSource.links.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(dataSource.links) { link in
                        Link(destination: link.destination) {
                            Label {
                                Text(link.title)
                                    .multilineTextAlignment(.leading)
                            } icon: {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .font(.caption2)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
