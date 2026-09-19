import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/export_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:path/path.dart' as p;

/// 手动加的单元一条素材都没挑时，**命令行这头也得拦**。
///
/// 2026-09-19 用户原话：「如果有某个单元没有底片，这个时候就不能导出，
/// 要提醒没有出来有个空的台词语义单元。」
///
/// 判据早就写好了（`unitsWithNothingToShow`），注释也写明了后果：
///
/// > 导出那边「没挑素材」一律走「用原片这一段」，而这些单元的
/// > `startMs`~`endMs` 根本不指向原片的任何位置——真让它跑下去，出来的是
/// > 一段空白或者直接崩在 ffmpeg 里，而人要等片子导完才发现。
///
/// 但它**只有界面那条路在用**（`export_dialog.dart`）。Agent 敲
/// `ishkafel export` 直接放行。
///
/// 这是同一个形状的第四次：界面做了、Agent 那条路没做（前三次是素材时长、
/// 画面自查、首帧图）。而这一次的后果最直接——**片子导出来是坏的**。
void main() {
  late Directory dataDir;
  setUp(() => dataDir = Directory.systemTemp.createTempSync('exportblock'));
  tearDown(() => dataDir.deleteSync(recursive: true));

  /// U1 是手动加的插入段（`hasSource: false`）；U2 来自原片
  RenewTask taskWithInsertedUnit() => RenewTask(
        id: 't1',
        name: '插入段任务',
        sourcePath: '/v/src.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime(2026, 9, 19),
        updatedAt: DateTime(2026, 9, 19),
        units: const [
          SemanticUnit(
            uid: 'u0',
            index: 0,
            startMs: 92253,
            endMs: 102253,
            transcript: '这是我后加的一句',
            hasSource: false,
            shots: [],
          ),
          SemanticUnit(
            uid: 'u1',
            index: 1,
            startMs: 0,
            endMs: 7000,
            transcript: '原片里本来就有的',
            shots: [Shot(startMs: 0, endMs: 7000)],
          ),
        ],
      );

  /// 方案里两个单元都写「保留原片」——U1 是插入段，保留原片等于没东西可放
  void writePlans(Directory dir, String taskId) {
    final f = File(p.join(dir.path, 'plans', '$taskId.json'))
      ..createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({
      'plans': [
        {
          'name': '变体1',
          'units': [
            {'unit': 0, 'mode': 'keepOriginal'},
            {'unit': 1, 'mode': 'keepOriginal'},
          ],
        },
      ],
    }));
  }

  test('插入段一条素材都没挑：命令行拒绝导出，并点名是哪一个', () async {
    final task = taskWithInsertedUnit();
    await FileTaskRepository(dataDir).save(task);
    writePlans(dataDir, task.id);

    final err = StringBuffer();
    final out = StringBuffer();
    final code = await runExportCommand(
      rest: [task.id],
      dataDir: dataDir,
      out: out,
      err: err,
    );

    expect(code, isNot(0),
        reason: '真让它跑下去，出来的是一段空白或者直接崩在 ffmpeg 里——'
            '而人要等片子导完才发现');
    final said = '$err$out';
    expect(said, contains('U1'),
        reason: '必须指着说是哪一个。只说「有单元没挑素材」，'
            '人（和 Agent）还得自己一个个找');
    expect(said, contains('还没挑素材'),
        reason: '和界面那条路说同一句话——两边说法不一样，'
            '人对着截图问「这是同一个错吗」都答不上来');
  });

  test('插入段挑了素材就放行——有东西可放，不该拦', () async {
    final task = taskWithInsertedUnit();
    await FileTaskRepository(dataDir).save(task);
    final f = File(p.join(dataDir.path, 'plans', '${task.id}.json'))
      ..createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({
      'plans': [
        {
          'name': '变体1',
          'units': [
            // 插入段整体替换成一条素材：这就是它的底片
            {'unit': 0, 'mode': 'whole', 'material': 114791},
            {'unit': 1, 'mode': 'keepOriginal'},
          ],
        },
      ],
    }));

    final err = StringBuffer();
    final out = StringBuffer();
    await runExportCommand(
      rest: [task.id],
      dataDir: dataDir,
      out: out,
      err: err,
    );

    expect('$err$out', isNot(contains('还没挑素材')),
        reason: '挑过素材的插入段有底片，拦下来会让人导不出去且不知道为什么');
  });
}
