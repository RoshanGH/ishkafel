import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_spec.dart';
import 'package:ishkafel/features/director/script_export_dialog.dart';

/// 脚本成片只出一条片子，但规格该选还得选——与其他模块同一套面板
void main() {
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
