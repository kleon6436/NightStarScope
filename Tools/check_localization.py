#!/usr/bin/env python3
"""ローカライズの取りこぼしを検出する。

このプロジェクトは「日本語の原文をキーにした String Catalog」方式のため、
キーの登録漏れや en 翻訳の欠落があっても英語環境で日本語が表示されるだけで、
ビルドは通ってしまう。その静かな退行を検出するのが目的。

検査内容:
  1. 日本語を含むカタログのキーに en 翻訳があり、state が translated であること
  2. Swift の日本語文字列リテラルがカタログのキーとして登録されていること
  3. en 訳の書式指定子が原文と同じ個数・同じ並びであること。並びが変わる場合は
     位置指定子 (%1$@ 形式) を使っていること

使い方:
    python3 Tools/check_localization.py
違反があれば内容を出力して終了コード 1 を返す。
"""
from __future__ import annotations

import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_PATH = os.path.join(REPO_ROOT, "NightScope", "Localizable.xcstrings")
SOURCE_ROOTS = ("NightScope", "NightScopeiOS")

# 中黒 (・) など、翻訳対象にならない約物は含めない。
JAPANESE = re.compile(r"[ぁ-ゟ゠-ヺーヽ-ヿ一-鿿]")
STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
INTERPOLATION = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")
FORMAT_SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ #0]*[\d.*]*(?:hh|h|ll|l|q|L|z|j|t)?[@dioufeEgGxXcsp%]")
POSITIONAL_SPECIFIER = re.compile(r"%\d+\$")

# 走査から除外するファイル。理由を必ず添えること。
EXCLUDED_FILES = {
    # 星空アシスタントのプロンプト・入力文。language == "ja" 分岐で英語版を持つ。
    "NightScope/Controllers/ObservationAdvisorService.swift",
    "NightScope/Controllers/ObservationAdvisorInputBuilder.swift",
    # SwiftUI プレビュー専用のダミーデータ。製品ビルドに含まれない。
    "NightScopeiOS/Views/iOSPreviewSupport.swift",
}

# 行単位の除外。開発者向けの文言や、表示に使われないリテラル。
EXCLUDED_LINE_MARKERS = (
    "assertionFailure(",
    "preconditionFailure(",
    "fatalError(",
    "logger.",
    "// l10n-ignore",
)


def load_catalog() -> dict:
    with open(CATALOG_PATH, encoding="utf-8") as f:
        return json.load(f)


def en_values(entry: dict) -> list[str]:
    """エントリの en 訳を列挙する。複数形バリエーションは全て返す。"""
    localization = entry.get("localizations", {}).get("en")
    if not localization:
        return []
    if "stringUnit" in localization:
        return [localization["stringUnit"].get("value", "")]
    values = []
    for variation in localization.get("variations", {}).values():
        for unit in variation.values():
            if "stringUnit" in unit:
                values.append(unit["stringUnit"].get("value", ""))
    return values


def en_states(entry: dict) -> list[str]:
    localization = entry.get("localizations", {}).get("en")
    if not localization:
        return []
    if "stringUnit" in localization:
        return [localization["stringUnit"].get("state", "")]
    states = []
    for variation in localization.get("variations", {}).values():
        for unit in variation.values():
            if "stringUnit" in unit:
                states.append(unit["stringUnit"].get("state", ""))
    return states


def check_missing_english(strings: dict) -> list[str]:
    problems = []
    for key in sorted(strings):
        if not JAPANESE.search(key):
            continue
        entry = strings[key]
        states = en_states(entry)
        if not states:
            problems.append(f"en 訳が無い: {key!r}")
            continue
        for state in states:
            if state != "translated":
                problems.append(f"en の state が {state!r}: {key!r}")
                break
    return problems


def specifier_kinds(text: str) -> list[str]:
    """書式指定子を「引数の種類」の並びに正規化する。%lld と %d は同じ扱い。"""
    kinds = []
    for specifier in FORMAT_SPECIFIER.findall(text):
        if specifier == "%%":
            continue
        conversion = specifier[-1]
        if conversion in "dioux X".replace(" ", ""):
            kinds.append("int")
        elif conversion in "feEgG":
            kinds.append("float")
        else:
            kinds.append("object")
    return kinds


def check_positional_specifiers(strings: dict) -> list[str]:
    problems = []
    for key in sorted(strings):
        source_kinds = specifier_kinds(key)
        # dashboard.cell.* のような記号キーは原文側に書式指定子が無く比較できない。
        if not source_kinds:
            continue
        for value in en_values(strings[key]):
            translated_kinds = specifier_kinds(value)
            if POSITIONAL_SPECIFIER.search(value):
                continue
            if len(translated_kinds) != len(source_kinds):
                problems.append(
                    f"書式指定子の個数が一致しない: {key!r} -> {value!r}"
                )
            elif translated_kinds != source_kinds:
                problems.append(
                    f"引数の並びが変わるため位置指定子が必要: {key!r} -> {value!r}"
                )
    return problems


def swift_files() -> list[str]:
    paths = []
    for root in SOURCE_ROOTS:
        for dirpath, _, filenames in os.walk(os.path.join(REPO_ROOT, root)):
            for filename in filenames:
                if filename.endswith(".swift"):
                    paths.append(os.path.join(dirpath, filename))
    return sorted(paths)


def strip_comment(line: str) -> str:
    """行コメントを落とす。文字列リテラル内の // は残す。"""
    in_string = False
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
        elif char == '"':
            in_string = not in_string
        elif char == "/" and not in_string and line[index + 1:index + 2] == "/":
            return line[:index]
    return line


SWIFT_ESCAPES = {
    '\\"': '"',
    "\\\\": "\\",
    "\\n": "\n",
    "\\t": "\t",
    "\\r": "\r",
    "\\0": "\0",
    "\\'": "'",
}


def unescape_swift(literal: str) -> str:
    """Swift のリテラル表記を実際の文字列へ戻す。カタログのキーと形を揃える。"""
    return re.sub(
        r"\\.",
        lambda m: SWIFT_ESCAPES.get(m.group(0), m.group(0)),
        literal,
    )


def key_candidates(literal: str) -> re.Pattern | None:
    """SwiftUI の補間を含むリテラルを、キーと照合するための正規表現に変換する。

    Text("\\(count) 枚") のキーは "%lld 枚" のように補間部分が書式指定子へ
    置き換わるため、補間を書式指定子のワイルドカードとして扱う。
    """
    if not INTERPOLATION.search(literal):
        return None
    parts = INTERPOLATION.split(literal)
    pattern = FORMAT_SPECIFIER.pattern.join(re.escape(part) for part in parts)
    return re.compile(f"^{pattern}$")


def check_unregistered_literals(strings: dict) -> list[str]:
    problems = []
    keys = set(strings)
    for path in swift_files():
        relative = os.path.relpath(path, REPO_ROOT)
        if relative in EXCLUDED_FILES:
            continue
        in_block_comment = False
        with open(path, encoding="utf-8") as f:
            for number, raw_line in enumerate(f, 1):
                line = raw_line
                if in_block_comment:
                    if "*/" not in line:
                        continue
                    line = line.split("*/", 1)[1]
                    in_block_comment = False
                if "/*" in line:
                    before, _, after = line.partition("/*")
                    if "*/" in after:
                        line = before + after.split("*/", 1)[1]
                    else:
                        line = before
                        in_block_comment = True
                code = strip_comment(line)
                if any(marker in code for marker in EXCLUDED_LINE_MARKERS):
                    continue
                for match in STRING_LITERAL.finditer(code):
                    literal = unescape_swift(match.group(1))
                    if not JAPANESE.search(literal):
                        continue
                    if literal in keys:
                        continue
                    pattern = key_candidates(literal)
                    if pattern and any(pattern.match(key) for key in keys):
                        continue
                    problems.append(f"カタログ未登録: {relative}:{number}: {literal!r}")
    return problems


def main() -> int:
    catalog = load_catalog()
    strings = catalog["strings"]

    problems = (
        check_missing_english(strings)
        + check_unregistered_literals(strings)
        + check_positional_specifiers(strings)
    )

    if problems:
        for problem in problems:
            print(problem)
        print(f"\n{len(problems)} 件の問題を検出しました。")
        return 1

    print(f"OK: {len(strings)} キーを検査しました。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
