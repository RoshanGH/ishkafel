import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **「这一段画面从哪儿来」全仓只许问一次。**
///
/// 同一个问题原来在三个地方各答了一遍：预览（`TrackPlanBuilder`）、
/// 导出（`ExportPlan`）、音频（`AudioTrackBuilder`）。规则还不完全一致，
/// 而不一致的后果是画面和声音对同一个单元给出不同答案——一边有声一边黑屏，
/// 哪儿都不报错（2026-09-08 真机：「添加的台词语义单元不能正常播放」）。
///
/// 现在这三处一律走 `baseChoiceOf` / `baseOf`（见
/// `docs/superpowers/specs/2026-09-14-底片-design.md`）。这条守卫盯着：
/// 别再在它们里面直接按 `unit.hasSource` 或 `task.sourcePath` 自己判一遍。
void main() {
  /// 这三个文件回答的是同一个问题，所以必须走同一份规则
  const guarded = [
    'lib/core/playback/track_plan_builder.dart',
    'lib/core/export/export_plan.dart',
    'lib/core/audio/audio_track_builder.dart',
  ];

  /// 去掉注释和字符串字面量——文档里写 `hasSource` 是在解释，不是在判断
  String codeOnly(String src) {
    final out = StringBuffer();
    for (final line in src.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('//') || t.startsWith('///') || t.startsWith('*')) {
        continue;
      }
      out.writeln(line.replaceAll(RegExp(r"'[^']*'"), "''"));
    }
    return out.toString();
  }

  for (final path in guarded) {
    test('$path 不自己判「有没有画面可放」，问 baseChoiceOf', () {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: '文件挪了位置就把这条守卫一起改');
      final code = codeOnly(file.readAsStringSync());

      expect(code, contains(RegExp(r'base(Choice)?Of\(')),
          reason: '这一处要回答「画面从哪儿来」，规则在 baseChoiceOf/baseOf 里');
      expect(code.contains('.hasSource'), isFalse,
          reason: '直接读 hasSource 就是在旁边又写了一份规则；'
              '判据交给 baseChoiceOf，它已经把「任务有没有原片」和'
              '「这个单元有没有原片来源」分开了');
    });
  }

  test('底片的解析只有这一份实现', () {
    final impl = File('lib/core/replacement/unit_base.dart');
    expect(impl.existsSync(), isTrue);

    // 别处再定义一个同名函数就等于分叉了
    final dupes = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (f.path.endsWith('core/replacement/unit_base.dart')) continue;
      final src = f.readAsStringSync();
      if (src.contains('BaseChoice baseChoiceOf(') ||
          src.contains('UnitBase? baseOf(')) {
        dupes.add(f.path);
      }
    }

    expect(dupes, isEmpty, reason: '底片规则出现了第二份实现：${dupes.join('、')}');
  });
}
