import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/agent_frames.dart';

/// 让 Agent **看得见画面**，而不是只读文字描述。
///
/// 用户的原话：「就像人看到这个东西一样，Agent 也要看到这个东西，
/// 然后拿这个东西去搜索出对应的分镜。」
///
/// 现在给它的候选只有 `thumbnailUrl`——miaoa 的**签名地址、会过期**，
/// 而且 Agent 读不了远程图。它需要的是**本地文件路径**：拿到路径就能
/// 直接看图，像人一样判断「这一镜像不像」。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('agent_frames_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('按内容指纹命名：同一段只抽一次，改了才重抽', () {
    final a = framePath(dir, videoPath: '/v/a.mp4', atMs: 1200);
    final b = framePath(dir, videoPath: '/v/a.mp4', atMs: 1200);
    expect(a, b);
    expect(framePath(dir, videoPath: '/v/a.mp4', atMs: 1300), isNot(a));
    expect(framePath(dir, videoPath: '/v/b.mp4', atMs: 1200), isNot(a));
  });

  test('落在专门的目录里，删得掉、认得出', () {
    expect(framePath(dir, videoPath: '/v/a.mp4', atMs: 0),
        contains('agent_frames'));
  });

  group('抽帧', () {
    test('已经抽过就直接给路径，不重跑 ffmpeg', () async {
      final path = framePath(dir, videoPath: '/v/a.mp4', atMs: 500);
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List.filled(64, 1));
      var ran = 0;
      final got = await ensureFrame(
        dataDir: dir,
        videoPath: '/v/a.mp4',
        atMs: 500,
        extract: (_, _, _) async {
          ran++;
          return true;
        },
      );
      expect(got, path);
      expect(ran, 0, reason: '每次进来重抽一遍几十帧，用户会觉得这软件真慢');
    });

    test('没抽过就抽一次', () async {
      var ran = 0;
      final got = await ensureFrame(
        dataDir: dir,
        videoPath: '/v/a.mp4',
        atMs: 500,
        extract: (video, out, ms) async {
          ran++;
          File(out)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(List.filled(64, 1));
          return true;
        },
      );
      expect(ran, 1);
      expect(got, isNotNull);
    });

    test('抽失败就返回 null——不给一个指向空文件的路径', () async {
      final got = await ensureFrame(
        dataDir: dir,
        videoPath: '/v/坏.mp4',
        atMs: 0,
        extract: (_, _, _) async => false,
      );
      expect(got, isNull);
    });

    test('抽出来是空文件也算失败', () async {
      final got = await ensureFrame(
        dataDir: dir,
        videoPath: '/v/a.mp4',
        atMs: 0,
        extract: (video, out, ms) async {
          File(out)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(<int>[]);
          return true;
        },
      );
      expect(got, isNull, reason: '0 字节的图 Agent 读不出东西，等于没有');
    });
  });
}
