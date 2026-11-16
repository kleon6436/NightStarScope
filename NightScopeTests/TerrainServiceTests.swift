import XCTest
@testable import NightScope
import Compression
import zlib

final class TerrainServiceTests: XCTestCase {

    func test_fetchProfile_noBundleData_returnsNil() async {
        let service = TerrainService(globalData: nil, highResData: nil)
        let profile = await service.fetchProfile(latitude: 35.0, longitude: 139.0)
        XCTAssertNil(profile, "バンドルデータなしでは nil を返すはず")
    }

    func test_fetchProfile_withBundleData_returns72Angles() async {
        let grid = makeUniformGrid(elevation: 100)
        let service = TerrainService(globalData: grid)
        let profile = await service.fetchProfile(latitude: 35.0, longitude: 139.0)
        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.horizonAngles.count, 72)
    }

    func test_fetchProfile_uniformTerrain_allAnglesSlightlyNegative() async {
        let grid = makeUniformGrid(elevation: 500)
        let service = TerrainService(globalData: grid)
        let profile = await service.fetchProfile(latitude: 0, longitude: 0)
        for angle in profile?.horizonAngles ?? [] {
            // 目の高さ 1.7m + 地球曲率でわずかに負になる
            XCTAssertLessThan(angle, 0, "一様地形では目の高さ分だけ負になるはず")
            XCTAssertGreaterThan(angle, -1.0, "一様地形では大きく負にはならないはず")
        }
    }

    func test_fetchProfile_cachesSameRoundedCoordinate() async {
        var computeCount = 0
        let grid = makeCountingGrid(counter: &computeCount, elevation: 0)
        let service = TerrainService(globalData: grid)

        _ = await service.fetchProfile(latitude: 35.1234, longitude: 139.5678)
        let countAfterFirst = computeCount

        _ = await service.fetchProfile(latitude: 35.1239, longitude: 139.5671)
        let countAfterSecond = computeCount

        XCTAssertEqual(countAfterFirst, countAfterSecond, "キャッシュがヒットすれば再計算されないはず")
    }

    func test_fetchProfile_wrapsLongitudeAcrossDateLine() async {
        let grid = makeElevationGrid(
            latCells: 2,
            lonCells: 4,
            elevations: [
                0, 0, 0, 0,
                600, 0, 0, 100
            ]
        )
        let service = TerrainService(globalData: grid)

        let profile = await service.fetchProfile(latitude: 0, longitude: 179.95)

        // horizonAngles[i] は方位 i×5° (0 = 北) なので、東は index 18。
        guard let horizonAngles = profile?.horizonAngles, horizonAngles.count == 72 else {
            return XCTFail("地平プロファイルを取得できませんでした")
        }
        let eastAngle = horizonAngles[18]
        XCTAssertGreaterThan(eastAngle, 0.0, "日付変更線を跨いでも東方向の地形を拾うはず")
    }

    // MARK: - Max Useful Distance & Adaptive Sampling

    func test_maxUsefulDistance_seaLevel() {
        // 海拜 0m: sqrt(2R*1.7) + sqrt(2R*4500) ≈ 4.65km + 7.57km ≈ 12.2km
        let dist = TerrainService.maxUsefulDistance(observerElevation: 0)
        XCTAssertGreaterThan(dist, 10_000, "海拜 0m でも 10km 以上はサンプルすべき")
        XCTAssertLessThanOrEqual(dist, 100_000, "100km キャップを超えないはず")
    }

    func test_maxUsefulDistance_highElevation() {
        // 標高 1000m: sqrt(2R*1001.7) + sqrt(2R*4500) ≈ 113km + 7.57km => 100kmキャップ
        let dist = TerrainService.maxUsefulDistance(observerElevation: 1000)
        XCTAssertEqual(dist, 100_000, accuracy: 1, "高標高では 100km キャップに到達するはず")
    }

    func test_adaptiveSampleDistances_filtersWithinMax() {
        let distances = TerrainService.adaptiveSampleDistances(maxDistance: 10_000)
        XCTAssertTrue(distances.allSatisfy { $0 <= 10_000 })
        XCTAssertEqual(distances.first ?? 0, 250, accuracy: 0.001)
        XCTAssertGreaterThan(distances.last ?? 0, 9_000, "上限付近までサンプルするはず")
    }

    func test_adaptiveSampleDistances_fullRange() {
        let distances = TerrainService.adaptiveSampleDistances(maxDistance: 100_000)
        XCTAssertGreaterThan(distances.last ?? 0, 98_000, "100km 近くまでサンプルするはず")
        // 尾根の取りこぼしを防ぐため、サンプル間隔は 250m〜1.5km に収まる
        let steps = zip(distances.dropFirst(), distances).map { $0 - $1 }
        XCTAssertTrue(steps.allSatisfy { $0 >= 250 - 0.001 && $0 <= 1_500 + 0.001 })
        // 1 方位あたりのコストを抑える (72 方位 × 約 100 点)
        XCTAssertLessThanOrEqual(distances.count, 120)
    }

    func test_curvatureDrop_includesStandardRefraction() {
        // 10km 先: d²/(2R) = 7.85m、大気差 k=0.13 で 6.83m
        XCTAssertEqual(TerrainService.curvatureDrop(distance: 10_000), 6.83, accuracy: 0.01)
    }

    func test_fetchProfile_highResFallsBackToGlobal() async {
        // 高解像度グリッド（Version 2, 日本付近: lat 30–45, lon 130–145）
        let highResGrid = makeVersion2Grid(
            latMin: 30.0, latMax: 45.0, lonMin: 130.0, lonMax: 145.0,
            latCells: 2, lonCells: 2, elevation: 1000
        )
        // 全球グリッド（Version 1, -90〜90 / -180〜180）
        let globalGrid = makeUniformGrid(elevation: 200)

        let service = TerrainService(globalData: globalGrid, highResData: highResGrid)

        // 高解像度範囲外（ヨーロッパ付近）→ 全球グリッドから取得できる
        let profile = await service.fetchProfile(latitude: 48.0, longitude: 2.0)
        XCTAssertNotNil(profile, "高解像度範囲外でも全球グリッドからプロファイルを取得できるはず")
        XCTAssertEqual(profile?.horizonAngles.count, 72)
    }

    func test_elevationGridData_load_compressedELVZ() throws {
        let raw = makeElevationVersion1Data(latCells: 2, lonCells: 2, elevation: 123)
        // NSData.compressed(using: .zlib) はヘッダーなしの raw DEFLATE を出すため、
        // 実データ（Tools/prepare_srtm.py の zlib.compress）と同じ zlib 形式で圧縮する。
        let compressedPayload = try XCTUnwrap(referenceDeflate(raw))

        var fileData = Data([0x45, 0x4C, 0x56, 0x5A]) // "ELVZ"
        fileData.append(compressedPayload)

        let fileURL = try writeTemporaryFile(data: fileData)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let grid = ElevationGridData.load(from: fileURL)
        XCTAssertNotNil(grid)
        XCTAssertEqual(grid?.elevation(latitude: 0, longitude: 0) ?? .nan, 123, accuracy: 0.1)
    }

    func test_fetchProfile_realYamanakakoData_hasPositiveTerrainAngles() async throws {
        let dataURL = repositoryRootURL().appendingPathComponent("NightScope/Data", isDirectory: true)
        let globalURL = dataURL.appendingPathComponent("elevation_global.bin.z")
        let japanURL = dataURL.appendingPathComponent("elevation_japan.bin.z")

        let globalGrid = ElevationGridData.load(from: globalURL)
        let highResGrid = ElevationGridData.load(from: japanURL)

        guard let globalGrid, let highResGrid else {
            throw XCTSkip("実データが ELEV/ELVZ 形式で未生成のためスキップ: \(globalURL.lastPathComponent), \(japanURL.lastPathComponent)")
        }

        let service = TerrainService(globalData: globalGrid, highResData: highResGrid)
        let profile = await service.fetchProfile(latitude: 35.4175, longitude: 138.8628)

        guard let profile else {
            return XCTFail("山中湖座標で地形プロファイルを取得できませんでした")
        }

        let maxAngle = profile.horizonAngles.max() ?? -.infinity
        XCTAssertGreaterThan(maxAngle, 1.0, "山中湖では周囲地形により遮蔽仰角が正になるはず")
    }

    // MARK: - Decode equivalence

    /// 圧縮グリッドの展開経路（ヘッダー先読み＋事前確保バッファへの直接展開）が、
    /// 従来の「全体を展開してから非圧縮パーサーへ渡す」経路と同じ標高を返す。
    func test_elevationGridData_load_realData_matchesReferenceDecode() throws {
        for name in ["elevation_japan.bin.z", "elevation_global.bin.z"] {
            let url = repositoryRootURL().appendingPathComponent("NightScope/Data/\(name)")
            guard let fileData = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                throw XCTSkip("実データが未生成のためスキップ: \(name)")
            }
            let referenceRaw = try XCTUnwrap(referenceInflate(fileData.dropFirst(4)), name)
            let reference = try XCTUnwrap(ElevationGridData(data: referenceRaw), name)
            let decoded = try XCTUnwrap(ElevationGridData.load(from: url), name)

            var mismatches = 0
            for latStep in stride(from: -89.9, through: 89.9, by: 0.37) {
                for lonStep in stride(from: -179.9, through: 179.9, by: 0.53) {
                    if decoded.elevation(latitude: latStep, longitude: lonStep)
                        != reference.elevation(latitude: latStep, longitude: lonStep) {
                        mismatches += 1
                    }
                }
            }
            // 日本付近は細かく比較する
            for latStep in stride(from: 30.0, through: 46.0, by: 0.013) {
                for lonStep in stride(from: 128.0, through: 146.0, by: 0.017) {
                    if decoded.elevation(latitude: latStep, longitude: lonStep)
                        != reference.elevation(latitude: latStep, longitude: lonStep) {
                        mismatches += 1
                    }
                }
            }
            XCTAssertEqual(mismatches, 0, name)
        }
    }

    func test_elevationGridData_load_rejectsTrailingData() throws {
        var raw = makeElevationVersion1Data(latCells: 2, lonCells: 2, elevation: 1)
        raw.append(contentsOf: [0, 0])
        let compressed = try XCTUnwrap(referenceDeflate(raw))
        var fileData = Data([0x45, 0x4C, 0x56, 0x5A])
        fileData.append(compressed)
        let fileURL = try writeTemporaryFile(data: fileData)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertNil(ElevationGridData.load(from: fileURL), "ヘッダーのセル数と展開サイズが合わなければ読み込まない")
    }

    func test_elevationGridData_loadHeader_readsVersion2BoundsWithoutFullDecode() throws {
        let url = repositoryRootURL().appendingPathComponent("NightScope/Data/elevation_japan.bin.z")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("elevation_japan.bin.z が未生成のためスキップ")
        }
        let header = try XCTUnwrap(ElevationGridData.loadHeader(from: url))
        XCTAssertEqual(header.size, 32)
        XCTAssertEqual(header.latCells * header.lonCells, 2600 * 3200)
        XCTAssertLessThan(header.latMin, header.latMax)
        XCTAssertLessThan(header.lonMin, header.lonMax)
    }

    /// 遅延読み込み（範囲外なら高解像度グリッドを読まない）と、両グリッドを常に参照する従来経路が同じプロファイルを返す。
    /// 高解像度グリッドの範囲境界の外側近傍（サンプル点だけが範囲に入る地点）も含める。
    func test_fetchProfile_lazyHighResSkipping_matchesEagerProfiles() async throws {
        let dataURL = repositoryRootURL().appendingPathComponent("NightScope/Data", isDirectory: true)
        guard let globalGrid = ElevationGridData.load(from: dataURL.appendingPathComponent("elevation_global.bin.z")),
              let highResGrid = ElevationGridData.load(from: dataURL.appendingPathComponent("elevation_japan.bin.z")),
              let header = ElevationGridData.loadHeader(from: dataURL.appendingPathComponent("elevation_japan.bin.z"))
        else {
            throw XCTSkip("実データが未生成のためスキップ")
        }
        let eager = TerrainService(globalData: globalGrid, highResData: highResGrid)
        let globalOnly = TerrainService(globalData: globalGrid, highResData: nil)

        let midLat = (header.latMin + header.latMax) / 2
        let midLon = (header.lonMin + header.lonMax) / 2
        let coordinates: [(Double, Double)] = [
            (35.4175, 138.8628),                 // 山中湖（範囲内）
            (header.latMax + 0.5, midLon),       // 北端の外側 (サンプルは範囲に掛かる)
            (midLat, header.lonMin - 0.5),       // 西端の外側
            (midLat, header.lonMax + 0.8),       // 東端の外側
            (header.latMin - 0.85, midLon),      // 南端の外側
            (header.latMax + 1.05, midLon),      // 北端から到達距離 (≈0.9°) を少し超えた地点
            (midLat, header.lonMax + 1.6),       // 東端から到達距離を少し超えた地点
            (48.0, 2.0),                         // パリ（範囲から遠い）
            (-33.9, 151.2)                       // シドニー
        ]
        for (lat, lon) in coordinates {
            let expected = await eager.fetchProfile(latitude: lat, longitude: lon)
            let mayIntersect = TerrainService.samplingArea(latitude: lat, longitude: lon, mayIntersect: header)
            if !mayIntersect {
                // 範囲判定で高解像度グリッドを読まない地点は、全球グリッドだけの結果と一致するはず
                let globalOnlyProfile = await globalOnly.fetchProfile(latitude: lat, longitude: lon)
                XCTAssertEqual(globalOnlyProfile?.horizonAngles, expected?.horizonAngles, "\(lat),\(lon)")
            }
        }
        XCTAssertTrue(TerrainService.samplingArea(latitude: 35.4175, longitude: 138.8628, mayIntersect: header))
        XCTAssertTrue(TerrainService.samplingArea(latitude: header.latMax + 0.5, longitude: midLon, mayIntersect: header))
        XCTAssertFalse(TerrainService.samplingArea(latitude: 48.0, longitude: 2.0, mayIntersect: header))
    }

    /// 共有インスタンス（バンドルから遅延読み込み）と、事前に読み込んだグリッドを注入した結果が一致する。
    func test_fetchProfile_sharedLazyLoad_matchesEagerlyLoadedGrids() async throws {
        let dataURL = repositoryRootURL().appendingPathComponent("NightScope/Data", isDirectory: true)
        guard Bundle.main.url(forResource: "elevation_global", withExtension: "bin.z") != nil,
              let globalGrid = ElevationGridData.load(from: dataURL.appendingPathComponent("elevation_global.bin.z")),
              let highResGrid = ElevationGridData.load(from: dataURL.appendingPathComponent("elevation_japan.bin.z"))
        else {
            throw XCTSkip("テストホストに標高データが同梱されていないためスキップ")
        }
        let lazy = TerrainService()
        let eager = TerrainService(globalData: globalGrid, highResData: highResGrid)
        // 同時要求でも 1 回だけ読み込み、どちらも同じ結果になる
        async let first = lazy.fetchProfile(latitude: 35.4175, longitude: 138.8628)
        async let second = lazy.fetchProfile(latitude: 46.5, longitude: 7.9)
        let lazyResults = await [first, second]
        let eagerFirst = await eager.fetchProfile(latitude: 35.4175, longitude: 138.8628)
        let eagerSecond = await eager.fetchProfile(latitude: 46.5, longitude: 7.9)
        XCTAssertEqual(lazyResults[0]?.horizonAngles, eagerFirst?.horizonAngles)
        XCTAssertEqual(lazyResults[1]?.horizonAngles, eagerSecond?.horizonAngles)
        XCTAssertNotNil(lazyResults[0])
    }

    /// 旧実装と同じ方式（256KB チャンクで逐次展開）の参照デコーダ。
    private func referenceInflate(_ data: Data) -> Data? {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        let input = Data(data)
        return input.withUnsafeBytes { srcRaw -> Data? in
            guard let srcBase = srcRaw.bindMemory(to: Bytef.self).baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: srcBase)
            stream.avail_in = uInt(input.count)
            var output = Data()
            let chunkSize = 256 * 1024
            let outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { outBuffer.deallocate() }
            while true {
                stream.next_out = outBuffer
                stream.avail_out = uInt(chunkSize)
                let status = inflate(&stream, Z_NO_FLUSH)
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 { output.append(outBuffer, count: produced) }
                if status == Z_STREAM_END { return output }
                if status != Z_OK { return nil }
            }
        }
    }

    /// zlib 形式（ヘッダー付き）で圧縮する。Tools/prepare_srtm.py の zlib.compress と同じ形式。
    private func referenceDeflate(_ data: Data) -> Data? {
        var destinationLength = compressBound(uLong(data.count))
        var output = Data(count: Int(destinationLength))
        let status = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compress2(
                    dst.bindMemory(to: Bytef.self).baseAddress,
                    &destinationLength,
                    src.bindMemory(to: Bytef.self).baseAddress,
                    uLong(data.count),
                    9
                )
            }
        }
        guard status == Z_OK else { return nil }
        return output.prefix(Int(destinationLength))
    }

    // MARK: - Helpers

    private func makeUniformGrid(elevation: Int16) -> ElevationGridData? {
        makeElevationGrid(latCells: 2, lonCells: 4, elevation: elevation)
    }

    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func writeTemporaryFile(data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("terrain.bin.z")
        try data.write(to: fileURL)
        return fileURL
    }

    private func makeElevationVersion1Data(latCells: Int, lonCells: Int, elevation: Int16) -> Data {
        var data = Data()
        data.append(contentsOf: [0x45, 0x4C, 0x45, 0x56])

        var version = Int32(1).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &version) { Array($0) })

        var latitude = Int32(latCells).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &latitude) { Array($0) })

        var longitude = Int32(lonCells).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &longitude) { Array($0) })

        var elevationValue = elevation.littleEndian
        let cellBytes = withUnsafeBytes(of: &elevationValue) { Array($0) }
        for _ in 0..<(latCells * lonCells) {
            data.append(contentsOf: cellBytes)
        }

        return data
    }

    private func makeCountingGrid(counter: inout Int, elevation: Int16) -> ElevationGridData? {
        defer { counter += 1 }
        return makeElevationGrid(latCells: 2, lonCells: 4, elevation: elevation)
    }

    private func makeElevationGrid(latCells: Int, lonCells: Int, elevation: Int16) -> ElevationGridData? {
        ElevationGridData(data: makeElevationVersion1Data(latCells: latCells, lonCells: lonCells, elevation: elevation))
    }

    private func makeElevationGrid(latCells: Int, lonCells: Int, elevations: [Int16]) -> ElevationGridData? {
        XCTAssertEqual(elevations.count, latCells * lonCells)

        var data = Data()
        data.append(contentsOf: [0x45, 0x4C, 0x45, 0x56])

        var version = Int32(1).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &version) { Array($0) })

        var latitude = Int32(latCells).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &latitude) { Array($0) })

        var longitude = Int32(lonCells).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &longitude) { Array($0) })

        for elevation in elevations {
            var elevationValue = elevation.littleEndian
            data.append(contentsOf: withUnsafeBytes(of: &elevationValue) { Array($0) })
        }

        return ElevationGridData(data: data)
    }

    /// Version 2 (領域限定) 標高グリッドを生成するヘルパー。
    private func makeVersion2Grid(
        latMin: Float, latMax: Float, lonMin: Float, lonMax: Float,
        latCells: Int, lonCells: Int, elevation: Int16
    ) -> ElevationGridData? {
        var data = Data()
        data.append(contentsOf: [0x45, 0x4C, 0x45, 0x56])  // "ELEV"

        var version = UInt32(2).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &version) { Array($0) })

        var latC = Int32(latCells).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &latC) { Array($0) })

        var lonC = Int32(lonCells).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &lonC) { Array($0) })

        var latMinVal = latMin
        data.append(contentsOf: withUnsafeBytes(of: &latMinVal) { Array($0) })
        var latMaxVal = latMax
        data.append(contentsOf: withUnsafeBytes(of: &latMaxVal) { Array($0) })
        var lonMinVal = lonMin
        data.append(contentsOf: withUnsafeBytes(of: &lonMinVal) { Array($0) })
        var lonMaxVal = lonMax
        data.append(contentsOf: withUnsafeBytes(of: &lonMaxVal) { Array($0) })

        var elevationValue = elevation.littleEndian
        let cellBytes = withUnsafeBytes(of: &elevationValue) { Array($0) }
        for _ in 0..<(latCells * lonCells) {
            data.append(contentsOf: cellBytes)
        }

        return ElevationGridData(data: data)
    }
}
