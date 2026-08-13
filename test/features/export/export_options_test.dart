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

  testWidgets('五档分辨率、五档帧率、四档码率，跟剪映对齐', (tester) async {
    await pump(tester);
    expect(find.text('1080P（1080×1920）'), findsOneWidget);
    expect(find.text('30 fps'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('H.264'), findsOneWidget);
    expect(find.text('mp4'), findsOneWidget);
  });

  testWidgets('选了自定义码率才出输入框，并给出建议值', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('export-custom-kbps')), findsNothing);

    await pump(tester,
        spec: const ExportSpec(bitrate: BitrateMode.custom));
    expect(find.byKey(const Key('export-custom-kbps')), findsOneWidget);
    expect(find.textContaining('1080P 建议 ≥12000'), findsOneWidget);
  });

  testWidgets('选到 1080 以上时说清放大不会更清楚', (tester) async {
    // 素材本身是 1080 竖版，往上放大只让文件变大
    await pump(tester, spec: const ExportSpec(shortSide: 2160));
    expect(find.textContaining('往上放大不会更清楚'), findsOneWidget);
  });

  testWidgets('HEVC 与 mov 的代价要说出来，不能让人挑完才发现', (tester) async {
    await pump(tester, spec: const ExportSpec(codec: VideoCodec.hevc));
    expect(find.textContaining('编码慢得多'), findsOneWidget);

    await pump(tester, spec: const ExportSpec(format: ContainerFormat.mov));
    expect(find.textContaining('投放平台一般吃 mp4'), findsOneWidget);
  });
}
