import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_spec.dart';
import 'package:ishkafel/features/export/export_options_panel.dart';

/// 导出前要定的两件事：出多少条、出多大多清楚。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    int totalCombos = 24,
    int? pickCount,
    int durationMs = 0,
    ExportSpec spec = ExportSpec.standard,
    ValueChanged<int?>? onPick,
    ValueChanged<ExportSpec>? onSpec,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ExportOptionsPanel(
              spec: spec,
              onSpecChanged: onSpec ?? (_) {},
              totalCombos: totalCombos,
              pickCount: pickCount,
              durationMs: durationMs,
              onPickCountChanged: onPick ?? (_) {},
            ),
          ),
        ),
      ));

  testWidgets('缺省是全部导出，并把总条数写在按钮上', (tester) async {
    await pump(tester);
    expect(find.text('全部 24 条'), findsOneWidget);
    expect(find.text('挑差异最大的'), findsOneWidget);
  });

  testWidgets('切到「挑差异最大的」时给个默认条数，不用用户再点一下', (tester) async {
    int? picked = -1;
    await pump(tester, onPick: (n) => picked = n);
    await tester.tap(find.byKey(const Key('export-mode-pick')));
    expect(picked, 5);
  });

  testWidgets('条数选项不会超过总组合数——挑 20 条而只有 8 条组合是荒谬的',
      (tester) async {
    await pump(tester, totalCombos: 8, pickCount: 3);
    expect(find.byKey(const Key('export-pick-3')), findsOneWidget);
    expect(find.byKey(const Key('export-pick-5')), findsOneWidget);
    expect(find.byKey(const Key('export-pick-10')), findsNothing);
    expect(find.byKey(const Key('export-pick-20')), findsNothing);
  });

  testWidgets('只有一条组合时不摆这个开关——选了也没用', (tester) async {
    await pump(tester, totalCombos: 1);
    expect(find.byKey(const Key('export-mode-pick')), findsNothing);
    expect(find.textContaining('只有 1 条组合'), findsOneWidget);
  });

  testWidgets('说清「差异」是怎么算的，不做黑箱', (tester) async {
    await pump(tester, pickCount: 5);
    expect(find.textContaining('同一批拍摄'), findsOneWidget);
    expect(find.textContaining('每条素材都露一次面'), findsOneWidget);
  });

  testWidgets('剪映式版式：每个下拉带字段名，选项与剪映一致', (tester) async {
    await pump(tester);
    for (final label in ['分辨率', '帧率', '码率', '编码', '格式']) {
      expect(find.text(label), findsOneWidget, reason: '缺字段名的下拉没人看得懂');
    }
    expect(find.text('1080P'), findsOneWidget);
    expect(find.text('30fps'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('H.264'), findsOneWidget);
    expect(find.text('mp4'), findsOneWidget);
  });

  testWidgets('预计大小跟着规格变——这是感知档位差别的方式', (tester) async {
    // 60 秒 @ 推荐（12 Mbps）≈ 89MB
    await pump(tester, durationMs: 60000);
    final at12 = tester
        .widget<Text>(find.byKey(const Key('export-estimated-size')))
        .data!;

    await pump(tester,
        durationMs: 60000,
        spec: const ExportSpec(bitrate: BitrateMode.higher));
    final at18 = tester
        .widget<Text>(find.byKey(const Key('export-estimated-size')))
        .data!;
    expect(at12, isNot(at18), reason: '换了码率档预计大小必须跟着变');
  });

  testWidgets('时长未知时不显示预计大小——不摆一个编出来的数字', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('export-estimated-size')), findsNothing);
  });

  testWidgets('选了自定义码率才出输入框，并给出建议值', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('export-custom-kbps')), findsNothing);

    await pump(tester,
        spec: const ExportSpec(bitrate: BitrateMode.custom));
    expect(find.byKey(const Key('export-custom-kbps')), findsOneWidget);
    expect(find.textContaining('1080P 建议 ≥12000'), findsOneWidget);
  });
}
