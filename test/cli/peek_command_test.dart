import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/peek_command.dart';

/// 验收 Agent 的原话：「U3S2 那个 17.3 秒的坑位我是纯赌的」
/// 「画面对不对不是我验的，是你抽帧看的——这一条我不想含糊过去」。
///
/// 它拿不到候选时长、看不了画面、导完也没法确认成片对不对。人能做的三件事
/// 它一件都做不了，只能凭 description 猜。这条命令补的就是这个。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('peek'));
  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, dynamic> decode(StringBuffer out) =>
      jsonDecode(out.toString()) as Map<String, dynamic>;

  test('看一段视频：抽出帧来，路径给出去', () async {
    final video = File('${dir.path}/片子.mp4')..writeAsStringSync('fake');
    final out = StringBuffer();

    final code = await runPeekCommand(
      rest: [],
      dataDir: dir,
      videoPath: video.path,
      atMs: 2000,
      out: out,
      err: StringBuffer(),
      extract: (v, o, ms) async {
        File(o).writeAsStringSync('jpg');
        return true;
      },
      probeDurationMs: (_) async => 75300,
    );

    expect(code, 0);
    final json = decode(out);
    expect(json['durationMs'], 75300);
    expect(File(json['framePath'] as String).existsSync(), isTrue);
    expect(json['atMs'], 2000);
  });

  test('一次看好几个时间点——一帧看不出片子对不对', () async {
    final video = File('${dir.path}/片子.mp4')..writeAsStringSync('fake');
    final out = StringBuffer();

    await runPeekCommand(
      rest: [],
      dataDir: dir,
      videoPath: video.path,
      atMsList: '0,30000,70000',
      out: out,
      err: StringBuffer(),
      extract: (v, o, ms) async {
        File(o).writeAsStringSync('jpg');
        return true;
      },
      probeDurationMs: (_) async => 75300,
    );

    final frames = decode(out)['frames'] as List;
    expect(frames, hasLength(3));
    expect(frames.map((f) => (f as Map)['atMs']), [0, 30000, 70000]);
  });

  test('文件不在就直接说，别抽一半才报错', () async {
    final err = StringBuffer();

    final code = await runPeekCommand(
      rest: [],
      dataDir: dir,
      videoPath: '${dir.path}/没有这个.mp4',
      out: StringBuffer(),
      err: err,
      extract: (v, o, ms) async => true,
      probeDurationMs: (_) async => 0,
    );

    expect(code, isNot(0));
    expect(err.toString(), contains('没有这个.mp4'));
  });

  test('超出片长的时间点要说清，不能悄悄给最后一帧', () async {
    final video = File('${dir.path}/片子.mp4')..writeAsStringSync('fake');
    final err = StringBuffer();

    final code = await runPeekCommand(
      rest: [],
      dataDir: dir,
      videoPath: video.path,
      atMs: 999000,
      out: StringBuffer(),
      err: err,
      extract: (v, o, ms) async => true,
      probeDurationMs: (_) async => 75300,
    );

    expect(code, isNot(0));
    expect(err.toString(), contains('75.3'));
  });
}
