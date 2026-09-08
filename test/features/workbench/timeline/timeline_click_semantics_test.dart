import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_view.dart';

const _durationMs = 10000;
const _viewportWidth = 500.0;

/// U1 = 0~5000（S1 0~2000、S2 2000~5000），U2 = 5000~10000（S1 整段）
SegmentationEditorController _editor() => SegmentationEditorController(
      sentences: const [],
      initialUnits: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 5000,
          transcript: '前半段',
          shots: [
            Shot(startMs: 0, endMs: 2000),
            Shot(startMs: 2000, endMs: 5000),
          ],
        ),
        SemanticUnit(
          index: 1,
          startMs: 5000,
          endMs: _durationMs,
          transcript: '后半段',
          shots: [Shot(startMs: 5000, endMs: _durationMs)],
        ),
      ],
      durationMs: _durationMs,
      fps: 30,
    );

late SegmentationEditorController controller;
late List<(int, int?)> segments;

/// 可控时钟：tester.pump(Duration) 推进的是框架假时钟，DateTime.now() 不动
late DateTime now;
void _advance(Duration d) => now = now.add(d);

Future<void> _pump(WidgetTester tester) async {
  controller = _editor();
  segments = [];
  now = DateTime.utc(2026, 7, 31);
  final playhead = ValueNotifier<int>(0);
  addTearDown(playhead.dispose);

  tester.view.physicalSize = const Size(_viewportWidth, 400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: _viewportWidth,
        height: 400,
        child: TimelineView(
          controller: controller,
          geometry: const TimelineGeometry(
              durationMs: _durationMs, msPerPx: 20, scrollPx: 0),
          playhead: playhead,
          onSeek: (_) {},
          onGeometryChanged: (_) {},
          // 回调给的是**列表下标**（单元, 镜头），不是毫秒——毫秒要经过
          // 「原片 → 成片」换算，而 endMs 是开区间会落到相邻那一段身上
          onPlaySegment: (u, s) => segments.add((u, s)),
          clock: () => now,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 当前选中：(单元下标, 镜头下标)；镜头下标为 null 表示选中的是单元
(int, int?)? _selected() {
  final s = controller.selection;
  return s == null ? null : (s.unitIndex, s.shotIndex);
}

/// 各轨纵向中点
double get _unitsY => TimelineTracks.unitsTop + TimelineTracks.unitsH / 2;
double get _shotsY => TimelineTracks.shotsTop + TimelineTracks.shotsH / 2;

/// 每像素 20ms：3000ms → x=150（落在 U1 的 S2 里）
const _inShot2 = Offset(150, 0);

void main() {
  group('单击就是选中它自己（不再要求双击）', () {
    testWidgets('单击视觉镜头块立刻选中那个镜头', (tester) async {
      await _pump(tester);

      await tester.tapAt(Offset(_inShot2.dx, _shotsY));
      await tester.pump();

      expect(_selected(), (0, 1),
          reason: '点什么选什么。原来单击选的是「所在单元」，还要等 300ms 双击'
              '窗口超时才生效——点下去没反应，用户只会以为没点上');
    });

    testWidgets('单击不需要等待，pump 一帧就已生效', (tester) async {
      await _pump(tester);

      await tester.tapAt(Offset(_inShot2.dx, _shotsY));
      await tester.pump(); // 不给双击窗口的 300ms

      expect(controller.selection, isNotNull);
    });

    testWidgets('单击台词语义单元块选中那个单元', (tester) async {
      await _pump(tester);

      await tester.tapAt(Offset(_inShot2.dx, _unitsY));
      await tester.pump();

      expect(_selected(), (0, null));
    });
  });

  group('双击 = 播放这一段', () {
    testWidgets('双击视觉镜头：从它的起点播到它的终点', (tester) async {
      await _pump(tester);

      await tester.tapAt(Offset(_inShot2.dx, _shotsY));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(Offset(_inShot2.dx, _shotsY));
      await tester.pumpAndSettle();

      expect(segments, [(0, 1)],
          reason: '双击 S2 应当只播 S2 这一段（2.0s–5.0s）');
    });

    testWidgets('双击台词语义单元：播整个单元', (tester) async {
      await _pump(tester);

      await tester.tapAt(Offset(_inShot2.dx, _unitsY));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(Offset(_inShot2.dx, _unitsY));
      await tester.pumpAndSettle();

      expect(segments, [(0, null)]);
    });

    testWidgets('双击后选中态仍停在被双击的那一块', (tester) async {
      await _pump(tester);

      await tester.tapAt(Offset(_inShot2.dx, _shotsY));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(Offset(_inShot2.dx, _shotsY));
      await tester.pumpAndSettle();

      expect(_selected(), (0, 1),
          reason: '播一段的同时选中它，检查器里才对得上号');
    });

    testWidgets('单击不触发播放', (tester) async {
      await _pump(tester);

      await tester.tapAt(Offset(_inShot2.dx, _shotsY));
      await tester.pumpAndSettle();

      expect(segments, isEmpty,
          reason: '只是想选中却被播起来，会打断正在看的位置');
    });

    testWidgets('两次点击间隔过久算两次单击，不算双击', (tester) async {
      await _pump(tester);

      await tester.tapAt(Offset(_inShot2.dx, _shotsY));
      _advance(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.tapAt(Offset(_inShot2.dx, _shotsY));
      await tester.pumpAndSettle();

      expect(segments, isEmpty,
          reason: '隔了大半秒的两次点击是两次「选中」，不该突然播起来');
    });

    testWidgets('先后点两个不同的块，播的是后点的那个', (tester) async {
      await _pump(tester);

      // x=50 落在 U1 的 S1（0~2000）
      await tester.tapAt(Offset(50, _shotsY));
      _advance(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.tapAt(Offset(_inShot2.dx, _shotsY));
      await tester.pumpAndSettle();

      expect(segments, anyOf(isEmpty, [(0, 1)]),
          reason: '无论系统把它判成两次单击还是一次双击，'
              '都绝不能播成先点的那一块');
    });
  });
}
