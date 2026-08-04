import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/candidate_probe.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/features/picking/candidate_card.dart';
import 'package:ishkafel/features/picking/candidate_search_controller.dart';

const _longName =
    'JC_滴露_植源喷雾_XCT_SQ1&YY6_CH_千川直播_M66028501_0427_分镜12';

CandidateEntry _entry() => const CandidateEntry(
      material: CandidateMaterial(
        id: 76555,
        name: _longName,
        sceneDescription: '手持产品特写',
        thumbnailUrl: null,
        previewUrl: null,
        fileKey: null,
        tags: ['近景'],
      ),
      probing: false,
      spec: CandidateSpec(durationMs: 2000, width: 1080, height: 1920),
    );

Future<List<MethodCall>> _pump(WidgetTester tester) async {
  final clipboard = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') clipboard.add(call);
      return null;
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 160,
          height: 120,
          child: CandidateCard(
            entry: _entry(),
            selected: false,
            targetMs: 2000,
            onTap: () {},
            onPlay: () {},
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return clipboard;
}

void main() {
  testWidgets('点复制就把素材名放进剪贴板', (tester) async {
    final clipboard = await _pump(tester);

    await tester.tap(find.byKey(const Key('picking-copy-name-76555')));
    await tester.pumpAndSettle();

    expect(clipboard.single.arguments['text'], _longName,
        reason: '卡片上名字必然被截断，用户要拿完整的名字回 miaoa 里查');
  });

  testWidgets('复制后有反馈——「什么都没发生」的操作用户会连点好几次',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.byKey(const Key('picking-copy-name-76555')));
    await tester.pump();

    expect(find.textContaining('已复制'), findsOneWidget);
  });

  testWidgets('点复制不会顺带把这条候选选中', (tester) async {
    var picked = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 160,
            height: 120,
            child: CandidateCard(
              entry: _entry(),
              selected: false,
              targetMs: 2000,
              onTap: () => picked++,
              onPlay: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('picking-copy-name-76555')));
    await tester.pumpAndSettle();

    expect(picked, 0, reason: '想复制名字却顺手改了替换方案，是最难发现的误操作');
  });
}
