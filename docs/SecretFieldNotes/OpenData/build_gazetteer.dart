// 地名辞書アセットの生成(F-02-11)。
//
// OpenStreetMap の抽出から、駅・山・集落だけを取り出して
// `assets/places/gazetteer.tsv.gz` を作る。アプリはこのファイルを読むだけで、
// 実行時に外部へ問い合わせることはない(完全オフライン)。
//
// 使い方(生成手順の詳細は tool/README.md):
//   osmium tags-filter japan-latest.osm.pbf \
//     n/railway=station,halt n/natural=peak n/place=city,town,village,suburb \
//     -o places.osm.pbf
//   osmium export places.osm.pbf -f geojsonseq -o places.geojsonseq
//   dart run tool/build_gazetteer.dart places.geojsonseq assets/places/gazetteer.tsv.gz
//
// 出典・ライセンス: © OpenStreetMap contributors / ODbL 1.0
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

/// 出力の種別コード(place_gazetteer_repository.dart の _kindCodes と対応)
const _station = 's';
const _peak = 'p';
const _settlement = 't';

/// 集落として拾う place の値。`suburb` まで入れると数万件増えるので、
/// アセットが大きすぎる場合は最初にここから外す
const _settlementPlaces = {'city', 'town', 'village', 'suburb'};
const _stationRailways = {'station', 'halt'};

/// 生成物の先頭に置くライセンス表記(ODbL の表示義務。読み込み側は
/// `#` 始まりの行を読み飛ばす)
const _header = [
  '# 地名辞書 / place gazetteer',
  '# Source: OpenStreetMap (https://www.openstreetmap.org/)',
  '# © OpenStreetMap contributors, licensed under ODbL 1.0',
  '# https://opendatacommons.org/licenses/odbl/1-0/',
  '# columns: name\tkana\tlat\tlng\tkind(s=station,p=peak,t=settlement)',
];

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'usage: dart run tool/build_gazetteer.dart '
      '<places.geojsonseq> <out.tsv.gz>',
    );
    exitCode = 64;
    return;
  }
  final input = File(args[0]);
  if (!input.existsSync()) {
    stderr.writeln('入力が見つかりません: ${args[0]}');
    exitCode = 66;
    return;
  }

  // 同一地点の重複(node と way の二重マッピング等)を畳む。
  // キーは 名前+種別+小数3桁(約100m)で、同名でも離れていれば別物として残す
  final rows = <String, _Row>{};
  var skipped = 0;
  for (final line in input.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final Map<String, dynamic> feature;
    try {
      feature = jsonDecode(line) as Map<String, dynamic>;
    } on FormatException {
      skipped++;
      continue;
    }
    final row = _toRow(feature);
    if (row == null) {
      skipped++;
      continue;
    }
    rows.putIfAbsent(row.dedupeKey, () => row);
  }

  final sorted = rows.values.toList()
    ..sort((a, b) {
      final byName = a.name.compareTo(b.name);
      return byName != 0 ? byName : a.lat.compareTo(b.lat);
    });

  final buffer = StringBuffer();
  for (final line in _header) {
    buffer.writeln(line);
  }
  for (final row in sorted) {
    buffer.writeln(row.toTsv());
  }

  final out = File(args[1])..parent.createSync(recursive: true);
  out.writeAsBytesSync(GZipEncoder().encode(utf8.encode(buffer.toString())));

  final counts = <String, int>{};
  for (final row in sorted) {
    counts[row.kind] = (counts[row.kind] ?? 0) + 1;
  }
  stdout.writeln(
    '${sorted.length}件 '
    '(駅${counts[_station] ?? 0} / 山${counts[_peak] ?? 0} / '
    '集落${counts[_settlement] ?? 0}) → ${args[1]} '
    '${(out.lengthSync() / 1024).toStringAsFixed(0)}KB '
    '(除外 $skipped)',
  );
}

_Row? _toRow(Map<String, dynamic> feature) {
  final tags = feature['properties'];
  if (tags is! Map<String, dynamic>) return null;

  final kind = _kindOf(tags);
  if (kind == null) return null;

  // 日本語名のないものは出さない(N-07: 日本語のみ)
  var name = _firstString(tags, const ['name:ja', 'name']);
  if (name == null) return null;
  // 駅は「〜駅」に揃える(OSM には「佐賀」「佐賀駅」の両方の入り方がある)
  if (kind == _station && !name.endsWith('駅')) name = '$name駅';

  final kana = _firstString(tags, const [
    'name:ja_kana',
    'name:ja-Hira',
    'name:ja_hira',
  ]);

  final point = _centroid(feature['geometry']);
  if (point == null) return null;

  return _Row(
    name: name,
    // よみはひらがなに寄せる(照合側の正規化と同じ向きに揃えておく)
    kana: kana == null ? '' : _toHiragana(kana),
    lat: point.$1,
    lng: point.$2,
    kind: kind,
  );
}

String? _kindOf(Map<String, dynamic> tags) {
  if (_stationRailways.contains(tags['railway'])) return _station;
  if (tags['natural'] == 'peak') return _peak;
  if (_settlementPlaces.contains(tags['place'])) return _settlement;
  return null;
}

String? _firstString(Map<String, dynamic> tags, List<String> keys) {
  for (final key in keys) {
    final value = tags[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

/// 座標。Point 以外(山頂が way で入っている等)は頂点の平均で代表点を作る。
/// 順位付けと地図移動にしか使わないので、厳密な重心である必要はない。
(double, double)? _centroid(Object? geometry) {
  if (geometry is! Map<String, dynamic>) return null;
  final coordinates = geometry['coordinates'];
  final points = <List<num>>[];
  void collect(Object? node) {
    if (node is List && node.isNotEmpty) {
      if (node.first is num && node.length >= 2) {
        points.add(node.cast<num>());
      } else {
        for (final child in node) {
          collect(child);
        }
      }
    }
  }

  collect(coordinates);
  if (points.isEmpty) return null;
  var lng = 0.0;
  var lat = 0.0;
  for (final point in points) {
    lng += point[0].toDouble();
    lat += point[1].toDouble();
  }
  return (lat / points.length, lng / points.length);
}

/// カタカナ → ひらがな(長音符 ー はそのまま)
String _toHiragana(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    buffer.writeCharCode(rune >= 0x30A1 && rune <= 0x30F6 ? rune - 0x60 : rune);
  }
  return buffer.toString();
}

class _Row {
  _Row({
    required this.name,
    required this.kana,
    required this.lat,
    required this.lng,
    required this.kind,
  });

  final String name;
  final String kana;
  final double lat;
  final double lng;
  final String kind;

  /// 小数3桁 ≒ 100m。同名かつ同種で100m以内なら同一地物とみなす
  String get dedupeKey =>
      '$name|$kind|${lat.toStringAsFixed(3)}|${lng.toStringAsFixed(3)}';

  /// タブと改行は列区切りを壊すので落とす
  String _clean(String value) => value.replaceAll(RegExp(r'[\t\r\n]'), ' ');

  String toTsv() => [
    _clean(name),
    _clean(kana),
    lat.toStringAsFixed(5),
    lng.toStringAsFixed(5),
    kind,
  ].join('\t');
}
