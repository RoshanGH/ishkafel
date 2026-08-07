import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_view.dart';

const _durationMs = 10000;
const _viewportWidth = 500.0;

/// U1 = 0~5000（S1 0~2000、S2 2000~5000），U2 = 5000~10000（S1 整段）。
/// 全片打平的镜头下标：0、1、2
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

late List<(int, int)> ranges;
late List<BgmSegment> tapped;

const _track = BgmMaterial(
    id: 1, name: '轻快垫乐', durationMs: 8000, previewUrl: null);

Future<void> _pump(
  WidgetTester tester, {
  BgmPlan bgm = BgmPlan.empty,
  bool readOnly = false,
}) async {
  ranges = [];
  tapped = [];
  final playhead = ValueNotifier<int>(0);
  addTearDown(playhead.dispose);

  tester.view.physicalSize = const Size(_viewportWidth, 500);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: _viewportWidth,
        height: 500,
        child: TimelineView(
          controller: _editor(),
          geometry: const TimelineGeometry(
              durationMs: _durationMs, msPerPx: 20, scrollPx: 0),
          playhead: playhead,
          onSeek: (_) {},
          onGeometryChanged: (_) {},
          readOnly: readOnly,
          bgm: bgm,
          onBgmRangeSelected: (from, to) => ranges.add((from, to)),
          onBgmSegmentTap: tapped.add,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 配乐轨纵向中点
double get _bgmY => TimelineTracks.bgmTop + TimelineTracks.bgmH / 2;

/// 每像素 20ms：x=50 → 1000ms（S1）、x=150 → 3000ms（S2）、x=350 → 7000ms（S3）
Offset _at(double x) => Offset(x, _bgmY);

void main() {
  _voiceMarks();

  group('在配乐轨上横向拖选一段连续镜头', () {
    // 视口 500px 对应 10000ms：x=50 → 1000ms（U1）、x=350 → 7000ms（U2）
    testWidgets('在一个单元内部拖，就选中这一个单元', (tester) async {
      await _pump(tester);

      await tester.dragFrom(_at(50), const Offset(100, 0));
      await tester.pumpAndSettle();

      expect(ranges, [(0, 0)],
          reason: '配乐按台词语义单元对齐，吸附到单元边界而不是镜头');
    });

    testWidgets('拖过两个单元就选中这两个', (tester) async {
      await _pump(tester);

      await tester.dragFrom(_at(50), const Offset(300, 0));
      await tester.pumpAndSettle();

      expect(ranges, [(0, 1)]);
    });

    testWidgets('从右往左拖也认，回调里已经排好序', (tester) async {
      await _pump(tester);

      await tester.dragFrom(_at(350), const Offset(-300, 0));
      await tester.pumpAndSettle();

      expect(ranges, [(0, 1)]);
    });

    testWidgets('拖出片尾时夹到最后一个单元，选区不会突然消失', (tester) async {
      await _pump(tester);

      await tester.dragFrom(_at(350), const Offset(400, 0));
      await tester.pumpAndSettle();

      expect(ranges, [(1, 1)]);
    });

    testWidgets('只读回看时不给选——已导出的任务不该还能改配乐', (tester) async {
      await _pump(tester, readOnly: true);

      await tester.dragFrom(_at(50), const Offset(100, 0));
      await tester.pumpAndSettle();

      expect(ranges, isEmpty);
    });

    testWidgets('在别的轨上拖不会误触发配乐框选', (tester) async {
      await _pump(tester);

      await tester.dragFrom(
          Offset(50, TimelineTracks.shotsTop + TimelineTracks.shotsH / 2),
          const Offset(100, 0));
      await tester.pumpAndSettle();

      expect(ranges, isEmpty);
    });
  });

  group('点已有的一段', () {
    testWidgets('点在配乐块体上就把那一段交出去（用于换曲/移除）', (tester) async {
      await _pump(
        tester,
        bgm: const BgmPlan([
          BgmSegment(
              startUnit: 0, endUnit: 1, material: _track, fit: BgmFit.cut),
        ]),
      );

      await tester.tapAt(_at(50));
      await tester.pumpAndSettle();

      expect(tapped.single.material.name, '轻快垫乐');
    });

    testWidgets('点在没有配乐的地方什么都不发生', (tester) async {
      await _pump(
        tester,
        bgm: const BgmPlan([
          BgmSegment(
              startUnit: 0, endUnit: 0, material: _track, fit: BgmFit.cut),
        ]),
      );

      await tester.tapAt(_at(350));
      await tester.pumpAndSettle();

      expect(tapped, isEmpty);
    });
  });
}

/// 换过音色的单元要在时间线上看得出来——不然用户配完一轮就忘了改过哪几句
void _voiceMarks() {
  testWidgets('换过音色的单元与没换的画得不一样', (tester) async {
    final playhead = ValueNotifier<int>(0);
    addTearDown(playhead.dispose);
    tester.view.physicalSize = const Size(_viewportWidth, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<TimelinePainter> painterWith(VoicePlan voices) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: _viewportWidth,
            height: 500,
            child: TimelineView(
              controller: _editor(),
              geometry: const TimelineGeometry(
                  durationMs: _durationMs, msPerPx: 20, scrollPx: 0),
              playhead: playhead,
              onSeek: (_) {},
              onGeometryChanged: (_) {},
              voices: voices,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<TimelinePainter>()
          .first;
    }

    const vivi = VoiceRef(id: 'zh_female_vv_uranus_bigtts', name: 'vivi');
    final plain = await painterWith(VoicePlan.empty);
    final marked = await painterWith(VoicePlan.empty.assign([0], vivi));

    expect(marked.shouldRepaint(plain), isTrue,
        reason: '换了音色却不重画，时间线上永远看不到那道标记');
    expect(plain.shouldRepaint(plain), isFalse,
        reason: '没变还重画的话，播放时每秒白重画 30 次整条时间线');
  });
}
