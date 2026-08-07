import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/audio_track_builder.dart';
import 'package:ishkafel/core/audio/bgm_cache.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

const _a = BgmMaterial(
    id: 1, name: '尤克里里', durationMs: 30000, previewUrl: 'https://o/a.mp3');
const _b = BgmMaterial(
    id: 2, name: '风声', durationMs: 30000, previewUrl: 'https://o/b.mp3');

/// 五个单元，各 1 秒——配乐按单元对齐，测试也得有多个单元才谈得上「哪一段」
List<SemanticUnit> _units() => [
      for (var i = 0; i < 5; i++)
        SemanticUnit(
          index: i,
          startMs: i * 1000,
          endMs: (i + 1) * 1000,
          transcript: 'U${i + 1}',
          shots: [Shot(startMs: i * 1000, endMs: (i + 1) * 1000)],
        ),
    ];

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ishkafel_deg_'));
  tearDown(() => temp.deleteSync(recursive: true));

  /// 记录跑过哪些 ffmpeg，并把输出文件造出来
  ({AudioTrackBuilder builder, List<String> ran}) make(
      {required Set<int> broken}) {
    final ran = <String>[];
    return (
      builder: AudioTrackBuilder(
        run: (binary, args) async {
          ran.add(args.join(' '));
          await File(args.last).writeAsString('wav');
          return ProcessResult(1, 0, '', '');
        },
        workDir: temp,
        resolveBgm: (m) async {
          if (broken.contains(m.id)) {
            throw BgmUnavailableException('配乐「${m.name}」的地址已失效');
          }
          return '/local/${m.id}.mp3';
        },
      ),
      ran: ran,
    );
  }

  test('一段配乐取不到时，其余段落照常铺，人声也照常出', () async {
    final env = make(broken: {1});

    final out = await env.builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(),
      bgm: BgmPlan.empty
          .assign(startUnit: 0, endUnit: 1, materials: [_a], rangeMs: 2000)
          .assign(startUnit: 3, endUnit: 4, materials: [_b], rangeMs: 2000),
    );

    expect(out.path, isNotEmpty, reason: '整条作废的话，用户连人声和换过的音色都听不到');
    expect(env.ran.where((c) => c.contains('/local/2.mp3')), hasLength(1),
        reason: '好的那一段要照铺');
    expect(env.ran.where((c) => c.contains('/local/1.mp3')), isEmpty);
  });

  test('取不到的那条要点名报出去，用户才知道该重选哪一段', () async {
    final env = make(broken: {1});

    final out = await env.builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(),
      bgm: BgmPlan.empty
          .assign(startUnit: 0, endUnit: 1, materials: [_a], rangeMs: 2000),
    );

    expect(out.bgmWarnings.single, contains('尤克里里'));
    expect(out.bgmWarnings.single, contains('失效'));
  });

  test('全部配乐都取不到时也只是没配乐，不是没声音', () async {
    final env = make(broken: {1, 2});

    final out = await env.builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(),
      bgm: BgmPlan.empty
          .assign(startUnit: 0, endUnit: 1, materials: [_a], rangeMs: 2000)
          .assign(startUnit: 3, endUnit: 4, materials: [_b], rangeMs: 2000),
    );

    expect(out.path, isNotEmpty);
    expect(out.bgmWarnings, hasLength(2));
  });

  test('不注入解析器时用素材自带的地址——老行为不变', () async {
    final ran = <String>[];
    final builder = AudioTrackBuilder(
      run: (binary, args) async {
        ran.add(args.join(' '));
        await File(args.last).writeAsString('wav');
        return ProcessResult(1, 0, '', '');
      },
      workDir: temp,
    );

    await builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(),
      bgm: BgmPlan.empty
          .assign(startUnit: 0, endUnit: 1, materials: [_a], rangeMs: 2000),
    );

    expect(ran.where((c) => c.contains('https://o/a.mp3')), hasLength(1));
  });
}
