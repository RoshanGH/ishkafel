import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_spec.dart';
import 'package:ishkafel/features/director/script_export_dialog.dart';

/// 脚本成片只出一条片子，但规格该选还得选——与其他模块同一套面板
void main() {
  _saysWhatIsMissing();
  testWidgets('五项规格齐全；改了分辨率按新规格返回', (tester) async {
    late Future<ExportSpec?> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () => result = showScriptExportDialog(context,
                initial: ExportSpec.standard,
                durationMs: 128000,
                lineCount: 27),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    for (final label in const ['分辨率', '帧率', '码率', '编码', '格式']) {
      expect(find.text(label), findsOneWidget, reason: '$label 该能选');
    }
    expect(find.textContaining('27 句'), findsOneWidget);
    expect(find.text('预计大小'), findsOneWidget,
        reason: '选什么规格出多大的文件，不该让人猜');

    await tester.tap(find.byKey(const ValueKey('script-export-confirm')));
    await tester.pumpAndSettle();
    expect((await result)?.shortSide, ExportSpec.standard.shortSide);
  });

  testWidgets('取消 = 不导出', (tester) async {
    late Future<ExportSpec?> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () => result = showScriptExportDialog(context,
                initial: ExportSpec.standard, durationMs: 1000, lineCount: 1),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });
}

/// **导出对话框也要说「这一版少了哪几句」。**
///
/// 2026-09-10 真机走查：脚本 4 句、只有 1 句挑了镜头，对话框只写
/// 「1 句 · 3.2 秒」——另外 3 句去哪了一个字都没有。中栏那行橙字是编排时
/// 看的，人点开这个对话框就是在做「就导这个」的决定，不该要求他记得
/// 屏幕别处写过什么。
void _saysWhatIsMissing() {
  testWidgets('有句子没进这一版时，对话框点名说清', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showScriptExportDialog(
              context,
              initial: const ExportSpec(),
              durationMs: 3200,
              lineCount: 1,
              skipped: const {
                1: '还没挑镜头',
                2: '还没挑镜头',
                3: '还没挑镜头',
              },
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('script-export-skipped')), findsOneWidget);
    expect(find.textContaining('第 2–4 行未进预览：还没挑镜头'), findsOneWidget,
        reason: '要说得出是哪几句、为什么');
  });

  testWidgets('一句都没落下时不摆这块橙色——那是噪音', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showScriptExportDialog(
              context,
              initial: const ExportSpec(),
              durationMs: 12000,
              lineCount: 4,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('script-export-skipped')), findsNothing);
  });
}
