import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/voice_picker_sheet.dart';

const _vivi = VoiceRef(id: 'zh_female_vv_uranus_bigtts', name: 'vivi 2.0');

List<SemanticUnit> _units() => const [
      SemanticUnit(
          uid: 'u0',
          index: 0, startMs: 0, endMs: 2000, transcript: '第一句',
          shots: [Shot(startMs: 0, endMs: 2000)]),
      SemanticUnit(
          uid: 'u1',
          index: 1, startMs: 2000, endMs: 4000, transcript: '第二句',
          shots: [Shot(startMs: 2000, endMs: 4000)]),
      SemanticUnit(
          uid: 'u2',
          index: 2, startMs: 4000, endMs: 6000, transcript: '第三句',
          shots: [Shot(startMs: 4000, endMs: 6000)]),
    ];

Future<VoiceChoice?> _open(
  WidgetTester tester, {
  VoicePlan plan = VoicePlan.empty,
  int focused = 0,
}) async {
  VoiceChoice? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const Key('open'),
            onPressed: () async {
              result = await showVoicePicker(context,
                  units: _units(), plan: plan, focusedUnit: focused);
            },
            child: const Text('开'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  group('同时选「哪个音色」和「应用到哪几句」', () {
    testWidgets('默认只勾中当前那一句', (tester) async {
      await _open(tester, focused: 1);

      expect(
          tester.widget<CheckboxListTile>(find.byKey(const Key('voice-unit-1')))
              .value,
          isTrue);
      expect(
          tester.widget<CheckboxListTile>(find.byKey(const Key('voice-unit-0')))
              .value,
          isFalse);
    });

    testWidgets('勾上多句后一次换掉——U1/U3 用同一个音色', (tester) async {
      VoiceChoice? picked;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('open'),
                onPressed: () async {
                  picked = await showVoicePicker(context,
                      units: _units(),
                      plan: VoicePlan.empty,
                      focusedUnit: 0);
                },
                child: const Text('开'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('voice-unit-2')));
      await tester.pump();
      await tester.tap(find.byKey(Key('voice-option-${_vivi.id}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('voice-confirm')));
      await tester.pumpAndSettle();

      expect(picked!.unitIndexes, [0, 2],
          reason: '一句一句点，等于把同一件事做三遍');
      expect(picked!.voice!.id, _vivi.id);
    });

    testWidgets('没选音色时不给确认——避免产出一个空操作', (tester) async {
      await _open(tester);

      final btn = tester.widget<FilledButton>(
          find.byKey(const Key('voice-confirm')));
      expect(btn.onPressed, isNull);
    });

    testWidgets('按钮上写清楚要换几句', (tester) async {
      await _open(tester);
      expect(find.text('换这一句'), findsOneWidget);

      await tester.tap(find.byKey(const Key('voice-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('换这 3 句'), findsOneWidget);
    });
  });

  group('已经换过的单元要看得出来', () {
    testWidgets('列表里写上它现在用的音色名', (tester) async {
      await _open(tester,
          plan: VoicePlan.empty.assign(['u2'], _vivi), focused: 0);

      expect(find.textContaining('vivi 2.0'), findsWidgets,
          reason: '不写的话用户看不出哪几句已经处理过，只能靠记');
    });

    testWidgets('打开时默认选中当前单元已用的音色', (tester) async {
      await _open(tester,
          plan: VoicePlan.empty.assign(['u0'], _vivi), focused: 0);

      final btn = tester.widget<FilledButton>(
          find.byKey(const Key('voice-confirm')));
      expect(btn.onPressed, isNotNull, reason: '已有音色时确认键应当可用');
    });
  });

  group('改回原声', () {
    testWidgets('给出 null 音色，让调用方清掉这几句', (tester) async {
      VoiceChoice? picked;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('open'),
                onPressed: () async {
                  picked = await showVoicePicker(context,
                      units: _units(),
                      plan: VoicePlan.empty.assign(['u0'], _vivi),
                      focusedUnit: 0);
                },
                child: const Text('开'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('voice-revert')));
      await tester.pumpAndSettle();

      expect(picked!.voice, isNull);
      expect(picked!.unitIndexes, [0]);
    });
  });

  group('搜索', () {
    testWidgets('按名字过滤', (tester) async {
      await _open(tester);

      await tester.enterText(find.byKey(const Key('voice-search')), '云舟');
      await tester.pumpAndSettle();

      // find.text 会连输入框里的那份一起数到，按 option 的 key 断言更准
      expect(find.byKey(const Key('voice-option-zh_male_m191_uranus_bigtts')),
          findsOneWidget);
      expect(find.byKey(Key('voice-option-${_vivi.id}')), findsNothing);
    });

    testWidgets('搜不到时说清楚，不留白', (tester) async {
      await _open(tester);

      await tester.enterText(
          find.byKey(const Key('voice-search')), '不存在的音色');
      await tester.pumpAndSettle();

      expect(find.text('没有匹配的音色'), findsOneWidget);
    });
  });
}
