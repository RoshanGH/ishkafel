import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/candidate_probe.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/features/picking/candidate_card.dart';
import 'package:ishkafel/features/picking/candidate_row.dart';
import 'package:ishkafel/features/picking/candidate_search_controller.dart';
import 'package:ishkafel/features/picking/picking_messages.dart';

/// 视觉镜头替换一律「整条素材变速铺满原镜头时长」——软件不替人截素材。
/// 产品负责人 2026-09-09 定的方案，代价（倍速）必须在**挑的时候**看得见：
/// 真机上 102 条候选里 74 条比坑位长 3 倍以上，不标出来人挑完根本不知道
/// 自己选了一串快进。
///
/// 整体替换那一层不变速（时长跟着候选走），照旧标时长差。
CandidateEntry _entry(int durationMs) => CandidateEntry(
      material: const CandidateMaterial(
        id: 7,
        name: '素材',
        sceneDescription: '灶台上喷洒清洁剂',
        thumbnailUrl: null,
        previewUrl: null,
        fileKey: null,
        tags: [],
      ),
      probing: false,
      spec: CandidateSpec(durationMs: durationMs, width: 1080, height: 1920),
    );

Future<void> _pumpCard(
  WidgetTester tester, {
  required int durationMs,
  required int targetMs,
  required bool speedFit,
}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          height: 400,
          child: CandidateCard(
            entry: _entry(durationMs),
            selected: false,
            targetMs: targetMs,
            speedFitToSlot: speedFit,
            onTap: () {},
            onPlay: () {},
          ),
        ),
      ),
    ));

void main() {
  group('候选卡上的代价：变速那一层标倍速', () {
    testWidgets('20 秒素材配 0.5 秒坑位：标 40×，而不是「+19.5」', (tester) async {
      await _pumpCard(tester,
          durationMs: 20000, targetMs: 500, speedFit: true);

      expect(find.text('40×'), findsOneWidget,
          reason: '软件不截素材了，整条压进 0.5 秒就是 40 倍——'
              '「+19.5」说不清这一镜在成片里会变成一道闪光');
      expect(find.text('+19.5'), findsNothing);
    });

    testWidgets('长度对得上就不标——「1.01×」只是噪音', (tester) async {
      await _pumpCard(tester,
          durationMs: 2000, targetMs: 2000, speedFit: true);

      expect(find.byKey(const Key('picking-duration-delta-7')), findsNothing);
    });

    testWidgets('素材比坑位短：标慢放的倍数', (tester) async {
      await _pumpCard(tester,
          durationMs: 1000, targetMs: 4000, speedFit: true);

      expect(find.text('0.3×'), findsOneWidget);
    });

    testWidgets('整体替换那一层照旧标时长差——它不变速', (tester) async {
      await _pumpCard(tester,
          durationMs: 20000, targetMs: 500, speedFit: false);

      expect(find.text('+19.5'), findsOneWidget);
      expect(find.text('40×'), findsNothing);
    });
  });

  group('列表视图同样要标', () {
    testWidgets('行里也是倍速', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: CandidateRow(
              entry: _entry(20000),
              selected: false,
              targetMs: 500,
              speedFitToSlot: true,
              onTap: () {},
              onPlay: () {},
            ),
          ),
        ),
      ));

      expect(find.text('40×'), findsOneWidget);
    });
  });

  group('倍速文案与严重程度', () {
    test('探不到时长时不编一个数出来', () {
      expect(candidateSpeedText(candidateMs: null, slotMs: 500), isNull);
      expect(candidateSpeedText(candidateMs: 2000, slotMs: 0), isNull);
    });

    test('两位数倍率不带小数点——「40×」够了，「40.0×」只是占地方', () {
      expect(candidateSpeedText(candidateMs: 20000, slotMs: 500), '40×');
      expect(candidateSpeedText(candidateMs: 3000, slotMs: 2000), '1.5×');
    });

    test('1.25 倍以内算不出问题，2 倍是明显快进，再往上要红', () {
      expect(candidateSpeedSeverity(candidateMs: 1200, slotMs: 1000),
          SpeedSeverity.fine);
      expect(candidateSpeedSeverity(candidateMs: 1800, slotMs: 1000),
          SpeedSeverity.noticeable);
      expect(candidateSpeedSeverity(candidateMs: 20000, slotMs: 500),
          SpeedSeverity.severe);
      expect(candidateSpeedSeverity(candidateMs: 300, slotMs: 1000),
          SpeedSeverity.severe,
          reason: '慢放同样离谱，方向不同而已');
    });
  });
}
