import Foundation
import zlib

// MARK: - Elevation Grid Data

/// バンドルされた標高データを読み込む構造体。
///
/// バイナリフォーマット:
///
///   Version 1（全球）:
///   - Magic:     4 bytes  = 0x45 0x4C 0x45 0x56 ("ELEV")
///   - Version:   UInt32 LE = 1
///   - Lat cells: Int32  LE (南から北: -90 → +90)
///   - Lon cells: Int32  LE (西から東: -180 → +180)
///   - Data:      Int16[] LE, row-major, 標高 (メートル、海面上)
///
///   Version 2（領域限定）:
///   - Magic:     4 bytes  = 0x45 0x4C 0x45 0x56 ("ELEV")
///   - Version:   UInt32 LE = 2
///   - Lat cells: Int32  LE
///   - Lon cells: Int32  LE
///   - Lat min:   Float32 LE  (南端)
///   - Lat max:   Float32 LE  (北端)
///   - Lon min:   Float32 LE  (西端)
///   - Lon max:   Float32 LE  (東端)
///   - Data:      Int16[] LE, row-major, 標高 (メートル、海面上)
///
///   範囲外座標は 0m（平坦地）を返す。
///
///   圧縮フォーマット (ELVZ):
///   - Magic:     4 bytes  = 0x45 0x4C 0x56 0x5A ("ELVZ")
///   - Payload:   上記 Version 1/2 全体を zlib.compress(..., 9) で圧縮したデータ
///
/// 生成: Tools/prepare_srtm.py (Copernicus DEM GLO-30: CC BY 4.0)
struct ElevationGridData: Sendable {
    /// ファイル先頭のヘッダー情報。高解像度グリッドを読み込むべきかの判定にも使う。
    struct Header: Sendable, Equatable {
        let latCells: Int
        let lonCells: Int
        let latMin: Double
        let latMax: Double
        let lonMin: Double
        let lonMax: Double
        /// ヘッダーのバイト数 (Version 1 = 16, Version 2 = 32)。
        let size: Int

        var cellCount: Int { latCells * lonCells }

        /// 経度方向に全球を覆うグリッドかどうか。
        var spansAllLongitudes: Bool { (lonMax - lonMin) >= 359 }
    }

    private let latCells: Int
    private let lonCells: Int
    private let data: [Int16]
    private let latMin: Double
    private let latMax: Double
    private let lonMin: Double
    private let lonMax: Double

    private static let magic: [UInt8] = [0x45, 0x4C, 0x45, 0x56]  // "ELEV"
    private static let compressedMagic: [UInt8] = [0x45, 0x4C, 0x56, 0x5A]  // "ELVZ"
    private static let baseHeaderSize = 16
    private static let extendedHeaderSize = 32

    init?(data fileData: Data) {
        guard let header = fileData.withUnsafeBytes({ Self.parseHeader($0) }) else { return nil }
        guard fileData.count == header.size + header.cellCount * 2 else { return nil }

        var elevations = [Int16](repeating: 0, count: header.cellCount)
        fileData.withUnsafeBytes { src in
            elevations.withUnsafeMutableBytes { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[header.size...]))
            }
        }
        self.init(header: header, elevations: elevations)
    }

    private init(header: Header, elevations: [Int16]) {
        self.latCells = header.latCells
        self.lonCells = header.lonCells
        self.data = elevations
        self.latMin = header.latMin
        self.latMax = header.latMax
        self.lonMin = header.lonMin
        self.lonMax = header.lonMax
    }

    /// 非圧縮 ELEV ヘッダーを解析する。Version 1 は先頭 16 バイト、Version 2 は 32 バイトが必要。
    private static func parseHeader(_ bytes: UnsafeRawBufferPointer) -> Header? {
        guard bytes.count >= baseHeaderSize else { return nil }
        guard bytes[0..<4].elementsEqual(magic) else { return nil }

        let version = bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
        let latCells = Int(bytes.loadUnaligned(fromByteOffset: 8, as: Int32.self).littleEndian)
        let lonCells = Int(bytes.loadUnaligned(fromByteOffset: 12, as: Int32.self).littleEndian)
        guard latCells > 0, lonCells > 0 else { return nil }

        switch version {
        case 1:
            return Header(latCells: latCells, lonCells: lonCells,
                          latMin: -90.0, latMax: 90.0, lonMin: -180.0, lonMax: 180.0,
                          size: baseHeaderSize)
        case 2:
            guard bytes.count >= extendedHeaderSize else { return nil }
            return Header(
                latCells: latCells, lonCells: lonCells,
                latMin: Double(bytes.loadUnaligned(fromByteOffset: 16, as: Float32.self)),
                latMax: Double(bytes.loadUnaligned(fromByteOffset: 20, as: Float32.self)),
                lonMin: Double(bytes.loadUnaligned(fromByteOffset: 24, as: Float32.self)),
                lonMax: Double(bytes.loadUnaligned(fromByteOffset: 28, as: Float32.self)),
                size: extendedHeaderSize
            )
        default:
            return nil
        }
    }

    /// 指定座標の標高 (m) を返す。データ範囲外の場合は 0m を返す。
    func elevation(latitude: Double, longitude: Double) -> Double {
        let normalizedLongitude = normalizedLongitudeIfNeeded(longitude)
        guard latitude >= latMin, latitude <= latMax,
              normalizedLongitude >= lonMin, normalizedLongitude <= lonMax else { return 0.0 }
        let latIdx = Int((latitude - latMin) / (latMax - latMin) * Double(latCells))
            .clamped(to: 0..<latCells)
        let lonIdx = Int((normalizedLongitude - lonMin) / (lonMax - lonMin) * Double(lonCells))
            .clamped(to: 0..<lonCells)
        return Double(data[latIdx * lonCells + lonIdx])
    }

    /// 指定座標がこのグリッドの範囲内かどうかを返す。
    func contains(latitude: Double, longitude: Double) -> Bool {
        let normalizedLon = (lonMax - lonMin) >= 359 ? Self.normalizedLongitude(longitude) : longitude
        return latitude >= latMin && latitude <= latMax && normalizedLon >= lonMin && normalizedLon <= lonMax
    }

    private func normalizedLongitudeIfNeeded(_ longitude: Double) -> Double {
        guard (lonMax - lonMin) >= 359 else { return longitude }
        return Self.normalizedLongitude(longitude)
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        var normalized = longitude.truncatingRemainder(dividingBy: 360.0)
        if normalized <= -180.0 {
            normalized += 360.0
        } else if normalized > 180.0 {
            normalized -= 360.0
        }
        return normalized
    }

    /// バンドルファイル（非圧縮 ELEV または圧縮 ELVZ）から読み込む。
    /// ELVZ はヘッダーから展開後のサイズを求め、標高配列へ直接展開する（中間バッファなし）。
    static func load(from url: URL) -> ElevationGridData? {
        guard let fileData = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard fileData.count >= 4 else { return nil }
        if fileData[0..<4].elementsEqual(compressedMagic) {
            return fileData.withUnsafeBytes { inflateGrid(compressedFile: $0, headerOnly: false)?.grid }
        }
        return ElevationGridData(data: fileData)
    }

    /// ヘッダーだけを読む。ELVZ でも先頭 32 バイト分しか展開しないため、グリッド全体の読み込みより十分軽い。
    static func loadHeader(from url: URL) -> Header? {
        guard let fileData = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard fileData.count >= 4 else { return nil }
        if fileData[0..<4].elementsEqual(compressedMagic) {
            return fileData.withUnsafeBytes { inflateGrid(compressedFile: $0, headerOnly: true)?.header }
        }
        return fileData.withUnsafeBytes { parseHeader($0) }
    }

    /// ELVZ ファイル全体（マジック含む）を zlib 展開する。
    /// ヘッダーを先に展開してセル数を確定し、残りを事前確保した [Int16] へ 1 パスで書き込む。
    /// 展開後サイズがヘッダーと一致しない場合は nil を返す（非圧縮版の厳密サイズ検査と同等）。
    private static func inflateGrid(
        compressedFile: UnsafeRawBufferPointer,
        headerOnly: Bool
    ) -> (header: Header, grid: ElevationGridData?)? {
        let payloadOffset = compressedMagic.count
        guard compressedFile.count > payloadOffset,
              let fileBase = compressedFile.baseAddress else { return nil }

        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        stream.next_in = UnsafeMutablePointer<Bytef>(
            mutating: fileBase.advanced(by: payloadOffset).assumingMemoryBound(to: Bytef.self)
        )
        stream.avail_in = uInt(compressedFile.count - payloadOffset)

        // ヘッダー（最大 32 バイト）を展開する。Version 1 の場合は先頭 16 バイトのみ。
        var headerBytes = [UInt8](repeating: 0, count: extendedHeaderSize)
        let header: Header? = headerBytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  inflateExactly(&stream, into: base, count: baseHeaderSize) == .filled else { return nil }
            let version = UnsafeRawBufferPointer(rebasing: buffer[0..<baseHeaderSize])
                .loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            if version == 2 {
                guard inflateExactly(
                    &stream,
                    into: base.advanced(by: baseHeaderSize),
                    count: extendedHeaderSize - baseHeaderSize
                ) == .filled else { return nil }
                return parseHeader(UnsafeRawBufferPointer(buffer))
            }
            return parseHeader(UnsafeRawBufferPointer(rebasing: buffer[0..<baseHeaderSize]))
        }
        guard let header else { return nil }
        if headerOnly { return (header, nil) }

        var succeeded = false
        let elevations = [Int16](unsafeUninitializedCapacity: header.cellCount) { buffer, initializedCount in
            initializedCount = header.cellCount
            guard let base = buffer.baseAddress else { return }
            let byteCount = header.cellCount * MemoryLayout<Int16>.size
            guard inflateExactly(&stream, into: UnsafeMutableRawPointer(base), count: byteCount) == .filled else {
                // 展開失敗時も配列を初期化済みにしておく（結果は破棄する）
                UnsafeMutableRawPointer(base).initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
                return
            }
            succeeded = true
        }
        guard succeeded else { return nil }

        // 末尾に余分なデータが無いこと（= ストリーム終端）を確認する。
        if inflateExactly(&stream, into: nil, count: 0) != .streamEnd { return nil }
        return (header, ElevationGridData(header: header, elevations: elevations))
    }

    private enum InflateOutcome {
        /// 要求バイト数を埋めた（ストリームはまだ続く可能性がある）。
        case filled
        /// 要求バイト数を埋める前、または追加出力なしでストリーム終端に達した。
        case streamEnd
        case failed
    }

    /// 出力先 count バイトを埋めるまで inflate する。count == 0 の場合は終端確認のみ行う。
    private static func inflateExactly(
        _ stream: inout z_stream,
        into destination: UnsafeMutableRawPointer?,
        count: Int
    ) -> InflateOutcome {
        if count == 0 {
            // 1 バイトの退避先で終端まで進め、追加出力があればサイズ不一致として失敗にする。
            var scratch: UInt8 = 0
            return withUnsafeMutablePointer(to: &scratch) { pointer in
                while true {
                    stream.next_out = pointer
                    stream.avail_out = 1
                    let status = inflate(&stream, Z_NO_FLUSH)
                    if stream.avail_out == 0 { return .failed }
                    if status == Z_STREAM_END { return .streamEnd }
                    if status != Z_OK { return .failed }
                }
            }
        }
        guard let destination else { return .failed }
        stream.next_out = destination.assumingMemoryBound(to: Bytef.self)
        stream.avail_out = uInt(count)
        while stream.avail_out > 0 {
            let status = inflate(&stream, Z_NO_FLUSH)
            if status == Z_STREAM_END {
                return stream.avail_out == 0 ? .filled : .streamEnd
            }
            if status != Z_OK { return .failed }
        }
        return .filled
    }
}

private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(self, range.upperBound - 1))
    }
}

// MARK: - Service

/// 観測地周辺の地形データを提供する Actor。
/// Copernicus DEM バンドルデータから各方位の標高を読み込み、地球曲率・大気差と
/// 観測者の目の高さを考慮した地平仰角プロファイルを構築する。
/// 高解像度グリッド（日本等）があれば優先的に使い、範囲外は全球グリッドにフォールバックする。
/// バンドルデータが存在しない場合は nil を返す（平坦地扱い）。
actor TerrainService {
    private enum Constants {
        static let sampleCount = 72
        static let cachePrecisionDegrees = 0.001
        static let eyeHeightMeters = 1.7
        static let earthRadiusMeters = 6_371_000.0
        /// 標準大気差係数 k。光線の屈折で見かけの地球半径が R / (1 − k) に伸びる。
        static let refractionCoefficient = 0.13
        /// 最初のサンプル距離かつ最小サンプル間隔 (m)。高解像度グリッド (0.01° ≈ 1.1km) のセルより細かい。
        static let minSampleStepMeters = 250.0
        /// 距離に比例して広げるサンプル間隔の割合。
        static let sampleStepGrowthRatio = 0.05
        /// 最大サンプル間隔 (m)。全球グリッド (0.05° ≈ 5.5km) のセルより十分細かく、尾根を取りこぼさない。
        static let maxSampleStepMeters = 1_500.0
        /// 想定最高峰 (m)。最大サンプリング距離の計算に使用。
        static let maxPeakElevationMeters = 4_500.0
        /// 100km を超えると仰角 < 2° となり星空遮蔽への影響が小さいためキャップ。
        static let maxSamplingDistanceMeters = 100_000.0
        /// サンプリング距離候補 (m)。250m 間隔から距離の 5% ずつ広げ、最大 1.5km 間隔で 100km まで (約 100 点/方位)。
        static let sampleDistanceCandidates: [Double] = {
            var distances: [Double] = []
            var distance = Constants.minSampleStepMeters
            while distance <= Constants.maxSamplingDistanceMeters {
                distances.append(distance)
                let step = min(
                    max(Constants.minSampleStepMeters, distance * Constants.sampleStepGrowthRatio),
                    Constants.maxSampleStepMeters
                )
                distance += step
            }
            return distances
        }()
    }

    static let shared = TerrainService()

    /// グリッドの読み込み状態。読み込みは初回の fetchProfile で 1 度だけ（single-flight）行う。
    private enum GridSlot {
        case resolved(ElevationGridData?)
        case pending(@Sendable () -> ElevationGridData?)
        case loading(Task<ElevationGridData?, Never>)
    }

    private enum GridKind {
        case global
        case highRes
    }

    /// 同一座標の結果を再利用して地形プロファイル生成を抑制する。
    private let cache = NSCache<NSString, NSArray>()
    private var globalSlot: GridSlot
    private var highResSlot: GridSlot
    /// 高解像度グリッドの範囲。全体を展開せずに「この観測地で必要か」を判定するために使う。
    /// nil は未判定、.some(nil) はファイルなし。
    private var highResHeader: ElevationGridData.Header??
    private let highResHeaderLoader: @Sendable () -> ElevationGridData.Header?

    /// 読み込み済みのグリッドを直接注入する（テスト用）。
    init(globalData: ElevationGridData?, highResData: ElevationGridData? = nil) {
        self.globalSlot = .resolved(globalData)
        self.highResSlot = .resolved(highResData)
        self.highResHeaderLoader = { nil }
        // 注入時は範囲判定を行わず、常に高解像度グリッドを参照する（従来の挙動）。
        self.highResHeader = .some(highResData.map { _ in Self.unboundedHeader })
    }

    /// バンドルデータを初回使用時に遅延読み込みする。
    /// 全球グリッドは初回 fetchProfile で、高解像度グリッドは観測地のサンプル範囲が掛かるときだけ読む。
    init() {
        self.globalSlot = .pending { TerrainService.loadGlobalData() }
        self.highResSlot = .pending { TerrainService.loadHighResData() }
        self.highResHeaderLoader = { TerrainService.loadHeader(name: "elevation_japan") }
        self.highResHeader = nil
    }

    /// 注入されたグリッドに対して範囲判定を無効化するための全域ヘッダー。
    private static let unboundedHeader = ElevationGridData.Header(
        latCells: 1, lonCells: 1, latMin: -90, latMax: 90, lonMin: -180, lonMax: 180, size: 0
    )

    /// elevation_global (.bin.z / .bin) を読み込む。
    private static func loadGlobalData() -> ElevationGridData? {
        PerformanceSignposts.signposter.withIntervalSignpost("TerrainLoadGlobal") {
            loadFile(name: "elevation_global")
        }
    }

    /// elevation_japan (.bin.z / .bin) を読み込む。
    private static func loadHighResData() -> ElevationGridData? {
        PerformanceSignposts.signposter.withIntervalSignpost("TerrainLoadHighRes") {
            loadFile(name: "elevation_japan")
        }
    }

    /// 指定グリッドを読み込み済みにして返す。読み込み中なら同じ Task の完了を待つ。
    private func grid(_ kind: GridKind) async -> ElevationGridData? {
        switch slot(kind) {
        case .resolved(let grid):
            return grid
        case .loading(let task):
            return await task.value
        case .pending(let loader):
            let task = Task.detached(priority: .userInitiated) { loader() }
            setSlot(.loading(task), for: kind)
            let grid = await task.value
            setSlot(.resolved(grid), for: kind)
            return grid
        }
    }

    private func slot(_ kind: GridKind) -> GridSlot {
        switch kind {
        case .global: return globalSlot
        case .highRes: return highResSlot
        }
    }

    private func setSlot(_ slot: GridSlot, for kind: GridKind) {
        switch kind {
        case .global: globalSlot = slot
        case .highRes: highResSlot = slot
        }
    }

    /// 高解像度グリッドのヘッダーを（必要なら）読み、範囲を返す。ファイルなしは nil。
    private func resolvedHighResHeader() async -> ElevationGridData.Header? {
        if let highResHeader { return highResHeader }
        let loader = highResHeaderLoader
        let header = await Task.detached(priority: .userInitiated) { loader() }.value
        highResHeader = .some(header)
        return header
    }

    /// 観測地から最大サンプリング距離以内の点が高解像度グリッドの範囲に掛かるかどうか。
    /// 掛からなければ従来どおり全球グリッドの値だけが使われるため、高解像度グリッドを読まずに済む。
    nonisolated static func samplingArea(
        latitude: Double,
        longitude: Double,
        mayIntersect header: ElevationGridData.Header
    ) -> Bool {
        if header.spansAllLongitudes && header.latMin <= -90 && header.latMax >= 90 { return true }
        // 大円距離 100km の緯度方向の到達角 (≈ 0.9°) に余裕を持たせる。
        let reachDegrees = Constants.maxSamplingDistanceMeters / Constants.earthRadiusMeters * 180.0 / .pi
        let latMargin = reachDegrees * 1.1 + 0.01
        guard latitude >= header.latMin - latMargin, latitude <= header.latMax + latMargin else { return false }
        if header.spansAllLongitudes { return true }
        let extremeLatitude = min(max(abs(header.latMin), abs(header.latMax), abs(latitude)) + latMargin, 89.0)
        let lonMargin = latMargin / cos(extremeLatitude * .pi / 180.0)
        let lon = normalizedLongitude(longitude)
        return lon >= header.lonMin - lonMargin && lon <= header.lonMax + lonMargin
    }

    /// name.bin.z / name.bin のヘッダーだけを読む。
    private static func loadHeader(name: String) -> ElevationGridData.Header? {
        for url in candidateURLs(name: name) {
            if let header = ElevationGridData.loadHeader(from: url) {
                return header
            }
        }
        return nil
    }

    /// name.bin.z（圧縮）→ name.bin（非圧縮）の順で Bundle.main を検索して読み込む。
    private static func loadFile(name: String) -> ElevationGridData? {
        for url in candidateURLs(name: name) {
            if let data = ElevationGridData.load(from: url) {
                return data
            }
        }
        return nil
    }

    /// name.bin.z（圧縮）→ name.bin（非圧縮）の順で Bundle.main 内の候補 URL を返す。
    private static func candidateURLs(name: String) -> [URL] {
        let candidates: [(resource: String, ext: String)] = [
            (name, "bin.z"),
            ("\(name).bin", "z"),
            (name, "bin")
        ]
        var urls = candidates.compactMap { Bundle.main.url(forResource: $0.resource, withExtension: $0.ext) }

        let expectedCompressedName = "\(name).bin.z"
        urls += (Bundle.main.urls(forResourcesWithExtension: "z", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent == expectedCompressedName }

        let expectedPlainName = "\(name).bin"
        urls += (Bundle.main.urls(forResourcesWithExtension: "bin", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent == expectedPlainName }

        return urls
    }

    /// 観測地座標に対するプロファイルを返す。キャッシュがあればそれを使う。
    /// バンドルデータが存在しない場合は nil を返す（呼び出し元は平坦地として扱う）。
    /// 初回呼び出し時にバンドルデータをバックグラウンドで読み込む。
    func fetchProfile(latitude: Double, longitude: Double) async -> TerrainProfile? {
        let key = Self.cacheKey(latitude: latitude, longitude: longitude) as NSString
        if let cached = cache.object(forKey: key) as? [Double] {
            return TerrainProfile(horizonAngles: cached)
        }

        let globalData = await grid(.global)
        let highResHeader = await resolvedHighResHeader()
        var highResData: ElevationGridData?
        if let highResHeader,
           Self.samplingArea(latitude: latitude, longitude: longitude, mayIntersect: highResHeader) {
            highResData = await grid(.highRes)
        }
        // 高解像度グリッドを読まなかった場合でも、存在するなら従来どおりプロファイルを返す。
        guard globalData != nil || highResData != nil || highResHeader != nil else { return nil }
        if let cached = cache.object(forKey: key) as? [Double] {
            return TerrainProfile(horizonAngles: cached)
        }

        let angles = Self.computeAngles(
            latitude: latitude,
            longitude: longitude,
            globalData: globalData,
            highResData: highResData
        )
        cache.setObject(angles as NSArray, forKey: key)
        return TerrainProfile(horizonAngles: angles)
    }

    // MARK: - Private

    nonisolated static func cacheKey(latitude: Double, longitude: Double) -> String {
        let rLat = roundedCoordinateComponent(latitude)
        let rLon = roundedCoordinateComponent(normalizedLongitude(longitude))
        return "\(rLat),\(rLon)"
    }

    /// 観測者標高に基づき、地形が空を遮る可能性がある最大距離 (m) を返す。
    /// 幾何学的水平線距離: d_max = √(2R·h_obs) + √(2R·H_peak)
    nonisolated static func maxUsefulDistance(observerElevation: Double) -> Double {
        let R = Constants.earthRadiusMeters
        let hObs = max(observerElevation + Constants.eyeHeightMeters, 0)
        let dObs = (2 * R * hObs).squareRoot()
        let dPeak = (2 * R * Constants.maxPeakElevationMeters).squareRoot()
        return min(dObs + dPeak, Constants.maxSamplingDistanceMeters)
    }

    /// maxDistance 以内のサンプリング距離を返す。
    nonisolated static func adaptiveSampleDistances(maxDistance: Double) -> [Double] {
        Constants.sampleDistanceCandidates.filter { $0 <= maxDistance }
    }

    /// 高解像度グリッドを優先し、範囲外なら全球にフォールバック。両方 nil の場合は 0.0 を返す。
    private nonisolated static func elevation(
        latitude: Double,
        longitude: Double,
        globalData: ElevationGridData?,
        highResData: ElevationGridData?
    ) -> Double {
        if let hires = highResData {
            let val = hires.elevation(latitude: latitude, longitude: longitude)
            if val != 0.0 { return val }
            // 0.0 は範囲外の可能性があるので、座標がグリッド範囲内か確認
            if hires.contains(latitude: latitude, longitude: longitude) {
                return val
            }
        }
        return globalData?.elevation(latitude: latitude, longitude: longitude) ?? 0.0
    }

    /// バンドルデータから 72 方位の地平仰角を計算する。
    /// 各方位で約 100 点 (250m〜1.5km 間隔) をサンプリングし、最大仰角を採る。
    /// 地球曲率による沈み込みは標準大気差 (k = 0.13) を含めて d²/(2R)·(1 − k) とし、
    /// 観測者の目の高さ (1.7m) を考慮する。
    private nonisolated static func computeAngles(
        latitude: Double,
        longitude: Double,
        globalData: ElevationGridData?,
        highResData: ElevationGridData?
    ) -> [Double] {
        let obsElev = elevation(latitude: latitude, longitude: longitude,
                                globalData: globalData, highResData: highResData)
        let maxDist = maxUsefulDistance(observerElevation: obsElev)
        let distances = adaptiveSampleDistances(maxDistance: maxDist)
        let viewerHeight = obsElev + Constants.eyeHeightMeters

        return (0..<Constants.sampleCount).map { index in
            let bearing = Double(index) * 5.0
            return distances.reduce(-90.0) { highestAngle, sampleDistance in
                let (lat2, lon2) = destinationPoint(
                    lat: latitude,
                    lon: longitude,
                    bearing: bearing,
                    distanceM: sampleDistance
                )
                let targetElev = elevation(latitude: lat2, longitude: lon2,
                                           globalData: globalData, highResData: highResData)
                let curvatureDrop = Self.curvatureDrop(distance: sampleDistance)
                let apparentHeight = targetElev - viewerHeight - curvatureDrop
                let angle = atan2(apparentHeight, sampleDistance) * 180.0 / .pi
                return max(highestAngle, angle)
            }
        }
    }

    /// 距離 distance (m) 先の地点が、地球曲率と大気差により見かけ上沈む高さ (m)。
    nonisolated static func curvatureDrop(distance: Double) -> Double {
        distance * distance / (2.0 * Constants.earthRadiusMeters) * (1.0 - Constants.refractionCoefficient)
    }

    private nonisolated static func roundedCoordinateComponent(_ value: Double) -> Double {
        (value / Constants.cachePrecisionDegrees).rounded() * Constants.cachePrecisionDegrees
    }

    private nonisolated static func normalizedLongitude(_ longitude: Double) -> Double {
        var normalized = longitude.truncatingRemainder(dividingBy: 360.0)
        if normalized <= -180.0 {
            normalized += 360.0
        } else if normalized > 180.0 {
            normalized -= 360.0
        }
        return normalized
    }

    /// Haversine 公式: 距離 distanceM 先の方位 bearing にある座標を返す。
    private nonisolated static func destinationPoint(lat: Double, lon: Double,
                                  bearing: Double, distanceM: Double) -> (Double, Double) {
        let R    = Constants.earthRadiusMeters
        let d    = distanceM / R
        let lat1 = lat * .pi / 180
        let lon1 = lon * .pi / 180
        let brng = bearing * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(brng))
        let lon2 = lon1 + atan2(sin(brng) * sin(d) * cos(lat1),
                                cos(d) - sin(lat1) * sin(lat2))
        return (lat2 * 180 / .pi, normalizedLongitude(lon2 * 180 / .pi))
    }
}
