import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/script_command.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/ai/tag_dimension.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// **同一个参考镜不许识两次图。**
///
/// 一行 47 个参考镜、十几分钟、每镜一次识图，全是钱。调用方命令超时了
/// 再起一个是常态——此前替这件事挡枪的是任务锁，锁删掉之后，
/// 「这一镜打没打过」必须**每一镜开工前重读盘**来判，
/// 不能信循环外那份快照：那份快照里它们永远是空的。
void main() {
  late Directory dir;
  late File video;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tagreftwice');
    video = File('${dir.path}/ref.mp4')..writeAsStringSync('假视频');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  // 三个参考镜：0–1000、1000–2000、2000–3000
  ScriptDoc threeShots() => ScriptDoc([
        ScriptLine(
          id: 'l1',
          text: '一句台词',
          reference: LineRef(
            startMs: 0,
            endMs: 3000,
            cuts: const [1000, 2000],
          ),
        ),
      ], refVideoPath: video.path);

  RenewTask taskWith(ScriptDoc doc) => RenewTask(
        id: 'sc1',
        seq: 1,
        name: '片子',
        sourcePath: null,
        script: doc,
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 1),
      );

  /// 假 ffmpeg：真写出一个「帧文件」，好让抽帧那一段走得通
  Future<ProcessResult> fakeFfmpeg(String exe, List<String> args) async {
    final outPath = args.last;
    File(outPath)
      ..createSync(recursive: true)
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF]);
    return ProcessResult(0, 0, '', '');
  }

  test('三个参考镜里已经打过两个——这一轮只为剩下那一个付钱', () async {
    final repo = FileTaskRepository(dir);
    final doc = threeShots();
    final ref = doc.lines.first.reference!
        .withShotMeta(RefShotMeta(startMs: 0, description: '已经打过的第一镜'))
        .withShotMeta(RefShotMeta(startMs: 1000, description: '已经打过的第二镜'));
    await repo
        .save(taskWith(doc.setReferenceById('l1', ref)));

    final tagger = _CountingTagger();
    final log = StringBuffer();
    final out = StringBuffer();
    final code = await runScriptTagRefCommand(
      rest: const ['sc1'],
      dataDir: dir,
      line: 1,
      tagger: tagger,
      run: fakeFfmpeg,
      out: out,
      err: log,
    );

    expect(code, 0);
    expect(tagger.calls, 1, reason: '打过的两镜再识一次图就是再收一次费');
    expect(log.toString(), contains('第 1 个参考镜已经打过标了'));
    expect(log.toString(), contains('第 2 个参考镜已经打过标了'));
    expect(out.toString(), contains('"skipped":2'));
  });

  test('别的进程在这期间打完了后两镜——这一轮不再为它们付钱', () async {
    final repo = FileTaskRepository(dir);
    await repo.save(taskWith(threeShots()));

    late final _CountingTagger tagger;
    tagger = _CountingTagger(onCall: () async {
      if (tagger.calls != 1) return;
      // 第一镜还在识图的这一分钟里，另一个进程把后两镜打完落了盘
      final now = await repo.findById('sc1');
      final ref = now!.script!.lines.first.reference!
          .withShotMeta(RefShotMeta(startMs: 1000, description: '别人打的'))
          .withShotMeta(RefShotMeta(startMs: 2000, description: '别人打的'));
      await repo.save(now.copyWith(
          script: now.script!.setReferenceById('l1', ref),
          updatedAt: DateTime.now()));
    });

    final log = StringBuffer();
    final code = await runScriptTagRefCommand(
      rest: const ['sc1'],
      dataDir: dir,
      line: 1,
      tagger: tagger,
      run: fakeFfmpeg,
      out: StringBuffer(),
      err: log,
    );

    expect(code, 0);
    expect(tagger.calls, 1,
        reason: '后两镜盘上已经有描述了，只信循环外的快照就会再识两次图');
    expect(log.toString(), contains('第 2 个参考镜已经打过标了'));
    expect(log.toString(), contains('第 3 个参考镜已经打过标了'));
  });
}

class _CountingTagger extends ShotTagger {
  int calls = 0;
  final Future<void> Function()? onCall;

  _CountingTagger({this.onCall})
      : super(chat: ArkChatClient(apiKey: '不会被用到'));

  @override
  Future<ShotUnderstanding> understand({
    required List<List<int>> frames,
    required List<TagDimension> dimensions,
    String? constraint,
  }) async {
    calls++;
    if (onCall != null) await onCall!();
    return const ShotUnderstanding(description: '刚打出来的描述');
  }
}
