import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/subtitle_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';

/// 素材库里不少分镜**画面里自带烧录字幕**，而画面描述里一个字都看不出来。
/// 默认的白字黑描边盖不住它，成片上就是两行字打架，片子直接废
/// （验收 Agent 真机撞上：描述写「成人给小孩按摩额头」，画面底部烧着
/// 别家品牌的「冰冰凉凉的好舒服呀」）。
///
/// 软件一直有遮挡能力（底条 / 毛玻璃），但这条线以前连存都没处存，
/// 人和 Agent 都没得选。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sub');
    repo = FileTaskRepository(dir);
    await repo.save(RenewTask(
      id: 't1',
      name: '片子',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('切成毛玻璃：素材自带的字被那块模糊盖住', () async {
    final code = await runSubtitleCommand(
      rest: ['t1'],
      dataDir: dir,
      preset: 'blurBox',
      out: StringBuffer(),
      err: StringBuffer(),
    );

    expect(code, 0);
    expect((await repo.findById('t1'))!.subtitle.preset, SubtitlePreset.blurBox);
  });

  test('不给参数就报现状，顺便说清哪个预设能遮挡', () async {
    final out = StringBuffer();
    await runSubtitleCommand(
      rest: ['t1'],
      dataDir: dir,
      out: out,
      err: StringBuffer(),
    );

    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['preset'], 'whiteOutline');
    expect('${json['presets']}', contains('blurBox'));
    expect('${json['note']}', contains('盖'));
  });

  test('预设名写错要点名说清有哪几个，别只说无效', () async {
    final err = StringBuffer();
    final code = await runSubtitleCommand(
      rest: ['t1'],
      dataDir: dir,
      preset: '毛玻璃',
      out: StringBuffer(),
      err: err,
    );

    expect(code, isNot(0));
    expect(err.toString(), contains('blurBox'));
  });

  test('位置和字号也能调——两行字高度差出几十像素才是穿帮', () async {
    await runSubtitleCommand(
      rest: ['t1'],
      dataDir: dir,
      bottomRatio: '0.18',
      fontRatio: '0.04',
      out: StringBuffer(),
      err: StringBuffer(),
    );

    final style = (await repo.findById('t1'))!.subtitle;
    expect(style.bottomRatio, closeTo(0.18, 0.001));
    expect(style.fontRatio, closeTo(0.04, 0.001));
  });
}
