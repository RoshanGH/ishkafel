import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/frame_check.dart';
import 'package:ishkafel/core/ai/local_frame_check.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';

/// 一帧判不出一条素材里有没有产品露出。
///
/// 真机上栽过：素材 114801 首帧是一排 Dettol 滴露瓶（logo 清清楚楚）、
/// 尾帧右上角也有一瓶，**唯独中段那一帧是微波炉内部、什么产品都没有**——
/// 而我们只抽了中段，于是记成「无产品露出」。
///
/// `taggers.dart` 里早就写过同一个道理（「单帧只能看到一个静止姿态，
/// 判不出镜头里在发生什么」）。这是同一件事在第二条路上重来一遍。
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('lfc'));
  tearDown(() => tmp.deleteSync(recursive: true));

  ({List<List<String>> runs, List<List<String>> seen, LocalVideoFrameChecker c})
      make({FrameCheck? reply = const FrameCheck()}) {
    final runs = <List<String>>[];
    final seen = <List<String>>[];
    return (
      runs: runs,
      seen: seen,
      c: LocalVideoFrameChecker(
        checker: _Fake(reply, seen),
        thumbnails: ThumbnailService(run: (bin, args) async {
          runs.add(args);
          File(args.last).writeAsStringSync('jpg');
          return ProcessResult(1, 0, '', '');
        }),
        workDir: tmp,
      ),
    );
  }

  List<String> secondsOf(List<List<String>> runs) =>
      [for (final a in runs) a[a.indexOf('-ss') + 1]];

  test('抽头中尾三帧，不是只抽中段', () async {
    final m = make();
    await m.c.check(7, '/v/a.mp4', durationMs: 12000);
    expect(m.runs.length, 3);
    final at = secondsOf(m.runs).map(double.parse).toList();
    expect(at.first, lessThan(1.5), reason: '开头那一帧要真的靠开头');
    expect(at[1], closeTo(6.0, 0.5));
    expect(at.last, greaterThan(9.0), reason: '结尾那一帧要真的靠结尾');
  });

  test('三帧一起送进同一次调用——不是跑三次', () async {
    final m = make();
    await m.c.check(7, '/v/a.mp4', durationMs: 12000);
    expect(m.seen.length, 1, reason: '三帧问一次，跑三次是成倍花钱');
    expect(m.seen.single.length, 3);
  });

  test('素材很短时不抽重复的帧', () async {
    final m = make();
    await m.c.check(7, '/v/a.mp4', durationMs: 600);
    expect(secondsOf(m.runs).toSet().length, m.runs.length);
  });

  test('不知道时长：也不该退回单帧，按一个保守的跨度抽', () async {
    final m = make();
    await m.c.check(7, '/v/a.mp4');
    expect(m.runs.length, greaterThan(1));
  });

  test('看字的帧要比看画面的清楚——小字在 512 高上会糊掉', () async {
    final m = make();
    await m.c.check(7, '/v/a.mp4', durationMs: 12000);
    expect(m.runs.first[m.runs.first.indexOf('-vf') + 1], contains('720'));
  });

  test('抽出来的帧用完就删，不在盘上留过夜', () async {
    final m = make();
    await m.c.check(7, '/v/a.mp4', durationMs: 12000);
    expect(tmp.listSync().whereType<File>(), isEmpty);
  });

  test('模型看不成时帧也要删掉', () async {
    final m = make(reply: null);
    await expectLater(
        m.c.check(7, '/v/a.mp4', durationMs: 12000), throwsStateError);
    expect(tmp.listSync().whereType<File>(), isEmpty);
  });

  test('某一帧抽不出来也别整条放弃——剩下的帧照样能看出问题', () async {
    var n = 0;
    final seen = <List<String>>[];
    final c = LocalVideoFrameChecker(
      checker: _Fake(const FrameCheck(productBrand: '滴露'), seen),
      thumbnails: ThumbnailService(run: (bin, args) async {
        if (++n == 2) return ProcessResult(1, 1, '', '这一帧坏了');
        File(args.last).writeAsStringSync('jpg');
        return ProcessResult(1, 0, '', '');
      }),
      workDir: tmp,
    );
    final r = await c.check(7, '/v/a.mp4', durationMs: 12000);
    expect(r.productBrand, '滴露');
    expect(seen.single.length, 2);
  });

  test('一帧都抽不出来才算失败——那时不能说「画面没问题」', () async {
    final c = LocalVideoFrameChecker(
      checker: _Fake(const FrameCheck(), []),
      thumbnails: ThumbnailService(
          run: (bin, args) async => ProcessResult(1, 1, '', '坏了')),
      workDir: tmp,
    );
    await expectLater(c.check(7, '/v/a.mp4', durationMs: 12000), throwsA(anything));
  });
}

class _Fake implements FrameChecker {
  final FrameCheck? reply;
  final List<List<String>> seen;
  _Fake(this.reply, this.seen);
  @override
  Future<FrameCheck> check(List<String> imagePaths) async {
    seen.add(List.of(imagePaths));
    return reply ?? (throw StateError('看不了'));
  }
}
