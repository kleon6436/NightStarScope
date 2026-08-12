import XCTest
@testable import NightScope

/// String Catalog の整合性を検証する。
///
/// 日本語原文をキーにする方式のため、en 訳が欠けてもビルドは通り、
/// 英語環境で日本語が表示されるだけになる。その退行をテストで止める。
/// ソース側のリテラル登録漏れは `Tools/check_localization.py` が担当する。
final class LocalizationCatalogTests: XCTestCase {

    // MARK: - Catalog Loading

    private struct Catalog: Decodable {
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
        let variations: Variations?
    }

    private struct Variations: Decodable {
        let plural: [String: PluralCase]?
    }

    private struct PluralCase: Decodable {
        let stringUnit: StringUnit?
    }

    private struct StringUnit: Decodable {
        let state: String
        let value: String
    }

    private static let catalogURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // NightScopeTests
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("NightScope/Localizable.xcstrings")
    }()

    private func loadCatalog() throws -> [String: Entry] {
        let data = try Data(contentsOf: Self.catalogURL)
        return try JSONDecoder().decode(Catalog.self, from: data).strings
    }

    // MARK: - Helpers

    /// 日本語の文字を含むか。中黒などの約物のみの文字列は対象外とする。
    private func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3041...0x309F,            // ひらがな
                 0x30A0...0x30FA,            // カタカナ (中黒 0x30FB を除く)
                 0x30FC...0x30FF,            // 長音符以降
                 0x4E00...0x9FFF:            // 漢字
                return true
            default:
                return false
            }
        }
    }

    private func englishUnits(_ entry: Entry) -> [StringUnit] {
        guard let english = entry.localizations?["en"] else { return [] }
        if let unit = english.stringUnit {
            return [unit]
        }
        return english.variations?.plural?.values.compactMap(\.stringUnit) ?? []
    }

    /// 書式指定子を引数の種類の並びに正規化する。%d と %lld は同一視する。
    private func specifierKinds(_ text: String) -> [String] {
        let pattern = "%(?:\\d+\\$)?[-+ #0]*[\\d.*]*(?:hh|h|ll|l|q|L|z|j|t)?[@dioufeEgGxXcsp%]"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let specifier = String(text[matchRange])
            guard let conversion = specifier.last, conversion != "%" else { return nil }
            switch conversion {
            case "d", "i", "o", "u", "x", "X":
                return "int"
            case "f", "e", "E", "g", "G":
                return "float"
            default:
                return "object"
            }
        }
    }

    private func usesPositionalSpecifiers(_ text: String) -> Bool {
        text.range(of: "%\\d+\\$", options: .regularExpression) != nil
    }

    // MARK: - Tests

    /// 日本語を含む全てのキーが翻訳済みの en 訳を持つ。
    func test_everyJapaneseKeyHasTranslatedEnglish() throws {
        let strings = try loadCatalog()
        var failures: [String] = []

        for (key, entry) in strings where containsJapanese(key) {
            let units = englishUnits(entry)
            if units.isEmpty {
                failures.append("en 訳が無い: \(key)")
                continue
            }
            for unit in units where unit.state != "translated" {
                failures.append("en の state が \(unit.state): \(key)")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "英語表示が日本語のままになるキーがあります:\n" + failures.sorted().joined(separator: "\n")
        )
    }

    /// en 訳の書式指定子が原文と同じ個数・並びであるか、位置指定子を使っている。
    func test_englishFormatSpecifiersAreConsistent() throws {
        let strings = try loadCatalog()
        var failures: [String] = []

        for (key, entry) in strings {
            let sourceKinds = specifierKinds(key)
            // 記号キーは原文側に書式指定子が無く比較できない
            guard !sourceKinds.isEmpty else { continue }

            for unit in englishUnits(entry) where !usesPositionalSpecifiers(unit.value) {
                let translatedKinds = specifierKinds(unit.value)
                if translatedKinds.count != sourceKinds.count {
                    failures.append("書式指定子の個数が一致しない: \(key) -> \(unit.value)")
                } else if translatedKinds != sourceKinds {
                    failures.append("並びが変わるため位置指定子が必要: \(key) -> \(unit.value)")
                }
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "書式指定子が整合しないキーがあります:\n" + failures.sorted().joined(separator: "\n")
        )
    }
}
