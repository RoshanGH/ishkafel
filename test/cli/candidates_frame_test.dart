import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/shot_frame.dart';

/// 脚本成片那条线挑镜头时，参考画面的 `framePath` 是直接给的——
/// Agent 打开就能看。替换裂变只给一句文字描述，要自己再跑一次
/// `peek --video 原片 --at`，而且得自己算这一镜从第几毫秒开始。
///
/// 「凡是人在界面上看得见的，你都能拿到本地文件」——这条在替换裂变
/// 这一步上一直缺着：人点开那一镜就看见画面了，Agent 只看得到文字。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('shotframe'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('抽这一镜的中间那一帧——两端常踩在转场上', () async {
    var askedAt = -1;
    final path = await shotFramePath(
      dataDir: dir,
      sourcePath: '/tmp/原片.mp4',
      startMs: 1000,
      endMs: 3000,
      extract: (video, out, ms) async {
        askedAt = ms;
        File(out).writeAsStringSync('jpg');
        return true;
      },
    );

    expect(path, isNotNull);
    expect(askedAt, 2000, reason: '取中点：两端常踩在转场上，抽出来是糊的');
  });

  test('抽过的直接用，不重跑 ffmpeg', () async {
    var calls = 0;
    Future<String?> once() => shotFramePath(
          dataDir: dir,
          sourcePath: '/tmp/原片.mp4',
          startMs: 0,
          endMs: 1000,
          extract: (v, o, ms) async {
            calls++;
            File(o).writeAsStringSync('jpg');
            return true;
          },
        );

    await once();
    await once();

    expect(calls, 1);
  });

  test('没有原片就返回 null，不假装有图', () async {
    expect(
        await shotFramePath(
          dataDir: dir,
          sourcePath: null,
          startMs: 0,
          endMs: 1000,
          extract: (v, o, ms) async => true,
        ),
        isNull);
  });

  test('抽帧失败不抛——挑素材不该因为看不到原片图就整个失败', () async {
    expect(
        await shotFramePath(
          dataDir: dir,
          sourcePath: '/tmp/原片.mp4',
          startMs: 0,
          endMs: 1000,
          extract: (v, o, ms) async => throw Exception('ffmpeg 挂了'),
        ),
        isNull);
  });
}
