import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **一个坑位的字幕只能有一处说了算**（见 `slot_subtitles.dart`）。
///
/// 2026-09-08 真机，用户原话：「我改了字幕以后，烧录的字幕没有变化」「调整
/// 字幕的那个根本就不生效」。属性面板读了手改轨，预览的变速切片和导出各自
/// 直接按 ASR 现算——三条路各断在不同地方，而这类错不进任何日志，只有把片子
/// 导出来看一眼才发现。
///
/// 所以盯住调用点：谁想知道「这一镜烧哪几行字」，只能问 subtitleLinesForSlot。
void main() {
  /// 允许直接调底层 subtitleLinesInSlot 的地方
  const allowed = {
    // 它自己
    'lib/core/subtitle/subtitle_overlay.dart',
    // 唯一的出口
    'lib/core/subtitle/slot_subtitles.dart',
    // 脚本成片是另一条线：那边没有原片，也就没有「手改某一镜」这回事
    'lib/core/script/script_export.dart',
  };

  test('替换裂变这条线上，没人绕过 subtitleLinesForSlot 自己算字幕', () {
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final path = file.path;
      if (allowed.contains(path)) continue;
      if (file.readAsStringSync().contains('subtitleLinesInSlot(')) {
        offenders.add(path);
      }
    }

    expect(offenders, isEmpty,
        reason: '这些地方自己按 ASR 算字幕，用户手改的那一份到不了：\n'
            '${offenders.join('\n')}\n'
            '改成 subtitleLinesForSlot(track: ..., unitIndex: ..., shotIndex: ...)');
  });

  test('导出对话框把手改字幕传给了导出器', () {
    final src =
        File('lib/features/export/export_dialog.dart').readAsStringSync();

    expect(RegExp(r'subtitleTrack:').allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: '导出有「一条」和「多条组合」两个入口，只接一个的话，'
            '另一条路上人改的字幕就丢了');
  });

  test('命令行导出也传——Agent 拧得到的旋钮不能比人少', () {
    expect(File('lib/cli/commands/export_command.dart').readAsStringSync(),
        contains('subtitleTrack:'));
  });

  test('凡是接 ASR 句子的导出入口，必须同时接手改字幕轨', () {
    // exportAll 就是这么溜过去的：它转手调 exportCombinations，两边都接了
    // subtitleSentences，唯独中间这一手把 subtitleTrack 丢了——「导出全部」
    // 这条路上人改的字幕永远不生效，而另一条路是好的，更难想到。
    final src = File('lib/core/export/export_runner.dart').readAsStringSync();
    final entries = RegExp(r'\s(export\w+)\(\{').allMatches(src);

    expect(entries, isNotEmpty, reason: '没扫到导出入口，正则该更新了');

    var checked = 0;
    for (final m in entries) {
      final end = src.indexOf('}) async {', m.start);
      if (end < 0) continue;
      final body = src.substring(m.start, end);
      if (!body.contains('subtitleSentences')) continue;
      checked++;
      expect(body, contains('subtitleTrack'),
          reason: '${m.group(1)} 接了 ASR 句子却没接手改字幕轨——走这条路导出的'
              '片子，人改的字幕不生效');
    }
    expect(checked, greaterThanOrEqualTo(2),
        reason: '至少 exportAll 和 exportCombinations 两条路要被查到');
  });
}
