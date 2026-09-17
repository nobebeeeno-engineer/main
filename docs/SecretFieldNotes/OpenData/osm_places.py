#!/usr/bin/env python3
"""OSM の pbf から地名辞書を作る(F-02-11)。

osmium-tool(CLI)や Dart が入れられない環境向けに、`osmium tags-filter` +
`osmium export` + `build_gazetteer.dart` の一連を pyosmium
(`pip install osmium`)だけで代替する。

出力は拡張子で決まる:

  # pbf から辞書アセットを直接作る(Dart 不要・中間ファイル無し)
  python3 tool/osm_places.py japan-latest.osm.pbf assets/places/gazetteer.tsv.gz

  # 中間の GeoJSONSeq だけ出して、畳むのは build_gazetteer.dart に任せる
  python3 tool/osm_places.py japan-latest.osm.pbf places.geojsonseq
  dart run tool/build_gazetteer.dart places.geojsonseq \
      assets/places/gazetteer.tsv.gz

抜き出す種類と出力形式は tool/build_gazetteer.dart と揃えてある
(どちらで作っても同じ辞書になる)。**種類や形式を変えるときは両方直す。**

出典・ライセンス: © OpenStreetMap contributors / ODbL 1.0
"""

import gzip
import json
import sys

import osmium
import osmium.filter

# build_gazetteer.dart の _stationRailways / _settlementPlaces と同じ集合
STATION_RAILWAYS = {"station", "halt"}
SETTLEMENT_PLACES = {"city", "town", "village", "suburb"}

# 出力の種別コード(place_gazetteer_repository.dart の _kindCodes と対応)
STATION = "s"
PEAK = "p"
SETTLEMENT = "t"

# build_gazetteer.dart の _firstString と同じ優先順
NAME_KEYS = ("name:ja", "name")
KANA_KEYS = ("name:ja_kana", "name:ja-Hira", "name:ja_hira")

# 生成物の先頭に置くライセンス表記(ODbL の表示義務。読み込み側は
# `#` 始まりの行を読み飛ばす)。build_gazetteer.dart の _header と同じ
HEADER = [
    "# 地名辞書 / place gazetteer",
    "# Source: OpenStreetMap (https://www.openstreetmap.org/)",
    "# © OpenStreetMap contributors, licensed under ODbL 1.0",
    "# https://opendatacommons.org/licenses/odbl/1-0/",
    "# columns: name\tkana\tlat\tlng\tkind(s=station,p=peak,t=settlement)",
]


def kind_of(tags):
    """辞書に載せる種類。対象外なら None(= この node は捨てる)。"""
    if tags.get("railway") in STATION_RAILWAYS:
        return STATION
    if tags.get("natural") == "peak":
        return PEAK
    if tags.get("place") in SETTLEMENT_PLACES:
        return SETTLEMENT
    return None


def first_value(tags, keys):
    for key in keys:
        value = tags.get(key)
        if value and value.strip():
            return value.strip()
    return None


def to_hiragana(value: str) -> str:
    """カタカナ → ひらがな(長音符 ー はそのまま)。"""
    return "".join(
        chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in value
    )


def clean(value: str) -> str:
    """タブと改行は列区切りを壊すので落とす。"""
    return value.replace("\t", " ").replace("\r", " ").replace("\n", " ")


def candidate_nodes(path: str):
    """辞書に載りうる node だけを流す。

    node だけを見る(駅・山・集落はほぼ node。way/relation の駅は
    取りこぼすが、日本の OSM では実用上問題にならない)。

    **フィルタは C++ 側で掛ける**。日本の pbf は2億ノード超で、その大半は
    タグを持たない図形用の点。素の FileProcessor だと全部が Python の
    ループに上がってきて桁違いに遅くなるため、タグ無しと対象キー以外を
    ここで落としてから Python 側へ渡す。
    """
    return (
        osmium.FileProcessor(path, osmium.osm.NODE)
        .with_filter(osmium.filter.EmptyTagFilter())
        .with_filter(osmium.filter.KeyFilter("railway", "natural", "place"))
    )


def rows_from_pbf(path: str):
    """pbf を1回走査して (name, kana, lat, lng, kind) を作る。"""
    scanned = 0
    for node in candidate_nodes(path):
        scanned += 1
        tags = node.tags
        kind = kind_of(tags)
        if kind is None:
            continue
        # 日本語名のないものは出さない(N-07: 日本語のみ)
        name = first_value(tags, NAME_KEYS)
        if name is None:
            continue
        # 駅は「〜駅」に揃える(OSM には「佐賀」「佐賀駅」の両方の入り方がある)
        if kind == STATION and not name.endswith("駅"):
            name += "駅"
        kana = first_value(tags, KANA_KEYS)
        yield (
            clean(name),
            clean(to_hiragana(kana)) if kana else "",
            node.location.lat,
            node.location.lon,
            kind,
        ), scanned


def write_tsv_gz(path: str, source: str) -> int:
    # 同一地点の重複(node と way の二重マッピング等)を畳む。
    # キーは 名前+種別+小数3桁(約100m)で、同名でも離れていれば別物として残す
    rows = {}
    scanned = 0
    for row, scanned in rows_from_pbf(source):
        key = f"{row[0]}|{row[4]}|{row[2]:.3f}|{row[3]:.3f}"
        rows.setdefault(key, row)

    ordered = sorted(rows.values(), key=lambda r: (r[0], r[2]))
    with gzip.open(path, "wt", encoding="utf-8", newline="\n") as out:
        for line in HEADER:
            out.write(line + "\n")
        for name, kana, lat, lng, kind in ordered:
            out.write(f"{name}\t{kana}\t{lat:.5f}\t{lng:.5f}\t{kind}\n")

    counts = {code: 0 for code in (STATION, PEAK, SETTLEMENT)}
    for row in ordered:
        counts[row[4]] += 1
    print(
        f"対象候補 {scanned}件 → {len(ordered)}件 "
        f"(駅{counts[STATION]} / 山{counts[PEAK]} / 集落{counts[SETTLEMENT]}) "
        f"→ {path}"
    )
    return 0


def write_geojsonseq(path: str, source: str) -> int:
    """build_gazetteer.dart に渡す中間形式。畳みと整形は Dart 側が行う。"""
    written = 0
    scanned = 0
    with open(path, "w", encoding="utf-8", newline="\n") as out:
        for node in candidate_nodes(source):
            scanned += 1
            tags = node.tags
            if kind_of(tags) is None:
                continue
            keys = NAME_KEYS + KANA_KEYS + ("railway", "natural", "place")
            properties = {k: tags[k] for k in keys if k in tags}
            if not any(k in properties for k in NAME_KEYS):
                continue
            out.write(
                json.dumps(
                    {
                        "type": "Feature",
                        "properties": properties,
                        "geometry": {
                            "type": "Point",
                            "coordinates": [node.location.lon, node.location.lat],
                        },
                    },
                    ensure_ascii=False,
                )
            )
            out.write("\n")
            written += 1

    print(f"対象候補 {scanned}件 → {written}件を {path} に書き出し")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: python3 tool/osm_places.py <input.osm.pbf> "
            "<out.tsv.gz | out.geojsonseq>",
            file=sys.stderr,
        )
        return 64

    source, out = argv[1], argv[2]
    if out.endswith(".gz"):
        return write_tsv_gz(out, source)
    return write_geojsonseq(out, source)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
