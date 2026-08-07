import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/workbench/preview_composer.dart';

/// 三个单元，各一个镜头
List<SemanticUnit> _units() => [
      for (var i = 0; i < 3; i++)
        SemanticUnit(
          index: i,
          startMs: i * 4000,
          endMs: (i + 1) * 4000,
          transcript: 'U${i + 1}',
          shots: [Shot(startMs: i * 4000, endMs: (i + 1) * 4000)],
        ),
    ];

({PreviewComposer composer, List<List<String>> calls, List<int> fetched})
    _make(Directory dir) {
  final calls = <List<String>>[];
  final fetched = <int>[];
  return (
    composer: PreviewComposer(
      run: (binary, args) async {
        calls.add(args);
        await File(args.last).writeAsString('mp4');
        return ProcessResult(1, 0, '', '');
      },
      workDir: dir,
      fetchMaterial: (id) async {
        fetched.add(id);
        final f = File('${dir.path}/m$id.mp4')..writeAsStringSync('mp4');
        return f.path;
      },
      probeDurationMs: (path) async => 5200,
    ),
    calls: calls,
    fetched: fetched,
  );
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ishkafel_pc_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('没有替换时不合成，直接用原片——白跑一遍 ffmpeg 是浪费', () async {
    final env = _make(temp);

    final result = await env.composer.compose(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: const [],
      audioPath: null,
    );

    expect(result.videoPath, isNull, reason: 'null 表示「照旧播原片」');
    expect(env.calls, isEmpty);
  });

  test('用各槽位的预览版合成——不是第一个候选，是标了 ★ 的那个', () async {
    final env = _make(temp);

    await env.composer.compose(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [71, 72], previewId: 72),
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ],
      audioPath: null,
    );

    expect(env.fetched, [72],
        reason: '导出会把 71、72 都用上，预览只放标了 ★ 的那一个');
  });

  test('整体替换的画面原样接上，不变速', () async {
    final env = _make(temp);

    await env.composer.compose(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [71]),
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ],
      audioPath: null,
    );

    final clip = env.calls.firstWhere(
        (a) => a.contains('-i') && a[a.indexOf('-i') + 1].endsWith('m71.mp4'));
    expect(clip[clip.indexOf('-vf') + 1], isNot(contains('setpts')));
  });

  test('镜头替换按倍率变速——预览里也该看到加速的效果', () async {
    final env = _make(temp);

    await env.composer.compose(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.perShot(const {
          0: [71]
        }),
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ],
      audioPath: null,
    );

    final clip = env.calls.firstWhere(
        (a) => a.contains('-i') && a[a.indexOf('-i') + 1].endsWith('m71.mp4'));
    expect(clip[clip.indexOf('-vf') + 1], contains('setpts=PTS/1.3'),
        reason: '5.2 秒的候选填 4.0 秒的坑位');
  });

  test('没变的段落复用上一次的切片，只重渲染改动的那一段', () async {
    final env = _make(temp);
    await env.composer.compose(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [71]),
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ],
      audioPath: null,
    );
    final first = env.calls.length;

    // 只改 U1 的候选，U2/U3 的原片切片应当复用
    await env.composer.compose(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [72]),
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ],
      audioPath: null,
    );

    expect(env.calls.length - first, lessThan(first),
        reason: '每改一次就把整条片子重渲染一遍，预览会慢到没法用');
  });

  test('合成出来的成片时长按替换后的算', () async {
    final env = _make(temp);

    final result = await env.composer.compose(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [71]),
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ],
      audioPath: null,
    );

    expect(result.timeline.totalMs, 13200,
        reason: 'U1 从 4000 变成 5200，其余两个各 4000');
  });

  test('有外挂音轨时一起合进去——听到的和看到的是同一条', () async {
    final env = _make(temp);
    final audio = File('${temp.path}/mix.wav')..writeAsStringSync('wav');

    await env.composer.compose(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [71]),
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ],
      audioPath: audio.path,
    );

    expect(env.calls.any((a) => a.contains(audio.path)), isTrue);
  });
}
