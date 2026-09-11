import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/inspector_panel.dart';

/// **时间码要自报家门。**
///
/// 2026-09-11 用户：「我看你上面写的是取自原片后面跟了一个时间轴，但没有说
/// 清楚这个是原视频的帧数时间轴，还是原视频的秒数时间轴。如果是帧数了，
/// 是多少帧一秒？也没有。这对我造成了很大的困扰。」
///
/// `00:17.28` 在 30fps 下是 17.933 秒，按小数读差 0.65 秒。
void main() {
  SegmentationEditorController controller() => SegmentationEditorController(
        initialUnits: const [
          SemanticUnit(
            uid: 'u0',
            index: 0,
            startMs: 0,
            endMs: 4000,
            transcript: 'U1',
            shots: [
              Shot(startMs: 0, endMs: 2000),
              Shot(startMs: 2000, endMs: 4000),
            ],
          ),
        ],
        durationMs: 4000,
        fps: 30,
        sentences: const [],
      );

  Future<SegmentationEditorController> pump(WidgetTester tester,
      {required bool shot}) async {
    final c = controller();
    c.select(shot
        ? const EditorSelection.shot(0, 0)
        : const EditorSelection.unit(0));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          height: 900,
          child: InspectorPanel(controller: c, fps: 30),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('单元卡：时间码说明写清格式、帧率，还给一个能对照的例子',
      (tester) async {
    await pump(tester, shot: false);
    final legend = tester
        .widget<Text>(find.byKey(const Key('inspector-timecode-legend')))
        .data!;
    expect(legend, contains('分:秒.帧'));
    expect(legend, contains('30fps'));
    expect(legend, contains('第 28 帧'));
  });

  testWidgets('镜头卡也要有——人常常只看这一张', (tester) async {
    await pump(tester, shot: true);
    expect(find.byKey(const Key('inspector-timecode-legend')), findsOneWidget);
  });

  testWidgets('「开始/结束」要标出是哪条轴——只标「取自原片」最容易让人以为是同一件事',
      (tester) async {
    await pump(tester, shot: false);
    expect(find.text('成片开始'), findsOneWidget);
    expect(find.text('成片结束'), findsOneWidget);
    expect(find.text('开始'), findsNothing, reason: '光写「开始」说不清是哪条轴');
    expect(find.text('取自原片'), findsOneWidget);
  });

  testWidgets('镜头卡同理：上面两个是成片位置，下面那行才是原片出处',
      (tester) async {
    await pump(tester, shot: true);
    expect(find.text('成片开始'), findsOneWidget);
    expect(find.text('成片结束'), findsOneWidget);
    expect(find.text('镜头开始'), findsNothing);
    expect(find.text('取自原片'), findsOneWidget);
  });
}
