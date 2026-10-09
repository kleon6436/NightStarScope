#!/usr/bin/env python3
"""
Generate stars_fill.json from the HYG star database v4.1 (hygdata_v41.csv).

Source
------
  HYG Database v4.1 by David Nash / astronexus
  https://github.com/astronexus/HYG-Database  (hyg/CURRENT/hygdata_v41.csv)
  License: CC BY-SA 4.0 (attribution required; the derived stars_fill.json is
  an adaptation and is therefore also CC BY-SA 4.0).

  NOTE: Earlier versions of this script read the Yale Bright Star Catalogue
  (BSC5, ~9,000 stars, 3 columns). The bundled stars_fill.json (25,650 stars,
  mag <= 7.5, 4th column = B-V) was actually produced from HYG v4.1. This script
  reproduces that file byte-for-byte when NAMED_STARS holds the coordinates in
  use at the time (see "Reproducibility" below).

Output: NightScope/Data/stars_fill.json
Format: [[ra_deg, dec_deg, magnitude, bv?], ...]
  - ra/dec: J2000 degrees rounded to 3 decimals
  - magnitude: V rounded to 2 decimals
  - bv: B-V colour index (HYG "ci") rounded to 3 decimals; omitted when HYG has none
  - Rows keep HYG's file order (HYG id order); the Sun (id 0) is skipped.
  - Stars with mag > 7.5 are dropped.
  - Stars inside a +/-0.301 deg box (raw RA and Dec difference, not an
    angular distance) around any entry of NAMED_STARS are dropped, because
    StarCatalog.swift draws those stars itself.

Reproducibility
---------------
  The bundled file was generated while several named stars in StarCatalog.swift
  had wrong RA values. Those were corrected (StarCatalog.swift and NAMED_STARS
  below), so regenerating now yields a slightly different file: the corrected
  stars move out of the fill list and a few stars near the old wrong positions
  come back. StarCatalog also removes fill entries that duplicate a named star
  at load time, so the app is correct with either file.

Usage:
  python3 Tools/generate_stars.py [--input hygdata_v41.csv] [--output PATH]
"""
import argparse
import csv
import io
import json
import os
import urllib.request

HYG_URL = "https://raw.githubusercontent.com/astronexus/HYG-Database/main/hyg/CURRENT/hygdata_v41.csv"
MAX_MAGNITUDE = 7.5
# Exclusion half-width (degrees) applied to |dRA| and |dDec| separately.
NAMED_EXCLUSION_DEG = 0.301

# Named stars RA+Dec from StarCatalog.swift — used to exclude duplicates.
# Keep in sync with StarCatalog.namedStars.
NAMED_STARS = [
    (101.287, -16.716),  # シリウス
    ( 95.988, -52.696),  # カノープス
    (219.899, -60.835),  # ケンタウルスα
    (213.915,  19.182),  # アークトゥルス
    (279.234,  38.784),  # ベガ
    ( 79.172,  45.998),  # カペラ
    ( 78.634,  -8.201),  # リゲル
    (114.826,   5.225),  # プロキオン
    ( 24.429, -57.237),  # アケルナル
    ( 88.793,   7.407),  # ベテルギウス
    (210.956, -60.373),  # ハダル
    (297.696,   8.868),  # アルタイル
    (186.649, -63.099),  # アクルックス
    ( 68.980,  16.509),  # アルデバラン
    (201.298, -11.161),  # スピカ
    (247.352, -26.432),  # アンタレス
    (116.329,  28.026),  # ポルックス
    (344.413, -29.622),  # フォーマルハウト
    (310.358,  45.280),  # デネブ
    (191.930, -59.688),  # ミモザ
    (152.093,  11.967),  # レグルス
    (104.656, -28.972),  # アダラ
    (113.649,  31.888),  # カストル
    (263.402, -37.103),  # シャウラ
    (187.791, -57.113),  # ガクルックス
    ( 81.283,   6.350),  # ベラトリックス
    ( 81.573,  28.608),  # エルナト
    (138.300, -69.717),  # ミアプラキドゥス
    ( 84.053,  -1.202),  # アルニラム
    (332.058, -46.961),  # アルナイル
    (193.507,  55.960),  # アリオト
    ( 85.190,  -1.943),  # アルニタク
    (165.932,  61.751),  # ドゥベ
    ( 51.081,  49.861),  # ミルファク
    (107.098, -26.393),  # ウェゼン
    (125.628, -59.509),  # アヴィオル
    (264.330, -42.997),  # サルガス
    (206.885,  49.313),  # アルカイド
    (276.043, -34.385),  # カウス・オーストラリス
    ( 89.882,  44.948),  # メンカリナン
    (252.166, -69.028),  # アトリア
    ( 99.428,  16.400),  # アルヘナ
    (306.412, -56.735),  # ピーコック
    ( 37.954,  89.264),  # ポラリス
    ( 95.675, -17.956),  # ミルザム
    (141.897,  -8.659),  # アルファルド
    (154.993,  19.841),  # アルギエバ
    ( 31.793,  23.463),  # ハマル
    ( 10.897, -17.987),  # デネブ・カイトス
    (200.981,  54.925),  # ミザール
    (283.816, -26.297),  # ヌンキ
    (  2.097,  29.090),  # アルフェラッツ
    ( 17.433,  35.620),  # ミラク
    ( 86.939,  -9.670),  # サイフ
    (263.734,  12.560),  # ラスアルハゲ
    (222.676,  74.156),  # コキャブ
    ( 47.042,  40.956),  # アルゴル
    (340.654, -46.885),  # ティアキ
    (177.265,  14.572),  # デネボラ
    (190.379, -48.959),  # ムフルファイン
    (248.971, -28.216),  # タウ・スコルピ
    (305.557,  40.257),  # サドル
    (252.541, -34.293),  # イプシロン・スコルピ
    (240.083, -22.622),  # デシュッバ
    (165.460,  56.383),  # メラク
    (178.458,  53.695),  # フェクダ
    (345.944,  28.083),  # シェアト
    ( 14.177,  60.717),  # ガンマ・カシオペア
    (346.190,  15.205),  # マルカブ
    ( 45.570,   4.090),  # メンカル
    (168.527,  20.524),  # ゾズマ
    (285.653, -29.880),  # アスケラ
    (241.359, -19.805),  # グラフィアス
    (220.482, -47.388),  # アルファ・ルピ
    ( 21.454,  60.236),  # ルクバー
    (208.671,  18.398),  # ムフリド
    (275.249, -29.828),  # カウスメディア
    (296.565,  10.613),  # タラゼド
    (190.415,  -1.449),  # ポリマ
    (276.992, -25.422),  # カウスボレアリス
    (195.544,  10.959),  # ヴィンデミアトリックス
    (  3.309,  15.184),  # アルゲニブ
    (311.553,  33.970),  # ギエナ
    (296.244,  45.131),  # デルタ・キグヌス
    ( 95.740,  22.514),  # テジャト
    ( 83.000,  -0.300),  # ミンタカ
    (258.661,  14.390),  # ラスアルゲティ
    (257.595, -15.724),  # サビク
    (111.024, -29.303),  # アルドラ
    (269.151,  51.489),  # エルタニン
    ( 10.127,  56.537),  # シェダル
    (  2.294,  59.150),  # カフ
    ( 84.411,  21.143),  # ゼータ・タウリ
    (292.680,  27.960),  # アルビレオ
    (252.968, -38.047),  # ムー・スコルピ
    (286.735, -27.670),  # タウ・サジタリ
    (271.452, -30.424),  # アルナスル (γ2 Sgr)
    (230.182,  71.834),  # フルカド
    (100.983,  25.131),  # メブスダ
    (253.646, -42.361),  # ゼータ・スコルピ
    (258.038, -43.239),  # エータ・スコルピ
    (262.691, -37.296),  # ウプシロン・スコルピ
    (224.633, -43.133),  # ベータ・ルピ
    (286.353,  13.863),  # ゼータ・アクィラ
    (284.736,  32.690),  # スラファト
    (282.520,  33.363),  # シェリアク
    ( 28.599,  63.670),  # セギン
    (183.857,  57.033),  # メグレズ
    (146.463,  23.774),  # ラス・エラセド
    (151.833,  16.763),  # エータ・レオニス
    (154.171,  23.417),  # アドハフェラ
    (110.031,  21.982),  # ワサット
    (101.321,  12.896),  # アルツィル
    ( 56.871,  24.105),  # イータ・タウリ
    ( 28.660,  20.808),  # シェラト
    ( 64.948,  15.628),  # ガンマ・タウリ
    ( 65.734,  17.543),  # デルタ・タウリ
    ( 67.154,  19.180),  # エプシロン・タウリ
    ( 75.492,  43.823),  # アルマアズ
    (302.826,  -0.821),  # テータ・アクィラ
    (281.414, -26.991),  # ファイ・スゲータリ
]


def is_named(ra, dec, tol=NAMED_EXCLUSION_DEG):
    """Return True if star lies inside the exclusion box of any named star."""
    for nra, ndec in NAMED_STARS:
        if abs(ra - nra) <= tol and abs(dec - ndec) <= tol:
            return True
    return False


def load_hyg_text(path=None):
    """Read hygdata_v41.csv from a local path or download it."""
    if path:
        with open(path, newline="", encoding="utf-8") as f:
            return f.read()
    print(f"Downloading HYG v4.1 from {HYG_URL} ...")
    req = urllib.request.Request(HYG_URL, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read().decode("utf-8")


def parse_hyg(text):
    """Convert HYG CSV rows to [ra_deg, dec_deg, mag, bv?] fill-star rows."""
    stars = []
    for row in csv.DictReader(io.StringIO(text)):
        if row["id"] == "0":  # Sun
            continue
        try:
            mag = float(row["mag"])
            ra_deg = float(row["ra"]) * 15.0  # HYG RA is in hours
            dec_deg = float(row["dec"])
        except ValueError:
            continue
        if mag > MAX_MAGNITUDE:
            continue

        ra_r, dec_r, mag_r = round(ra_deg, 3), round(dec_deg, 3), round(mag, 2)
        if is_named(ra_r, dec_r):
            continue

        entry = [ra_r, dec_r, mag_r]
        ci = row["ci"].strip()
        if ci:
            try:
                entry.append(round(float(ci), 3))
            except ValueError:
                pass
        stars.append(entry)
    return stars


if __name__ == "__main__":
    default_out = os.path.join(os.path.dirname(__file__), "..", "NightScope", "Data", "stars_fill.json")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", help="local hygdata_v41.csv (downloaded when omitted)")
    parser.add_argument("--output", default=default_out, help="output JSON path")
    args = parser.parse_args()

    stars = parse_hyg(load_hyg_text(args.input))
    print(f"Parsed {len(stars)} fill stars (mag <= {MAX_MAGNITUDE}) from HYG v4.1.")

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w") as f:
        json.dump(stars, f, separators=(",", ":"))

    size_kb = os.path.getsize(args.output) / 1024
    print(f"Written to {args.output}  ({size_kb:.1f} KB)")
    print("Note: HYG is CC BY-SA 4.0 — the app must credit it (Settings → Data Sources & Credits).")
