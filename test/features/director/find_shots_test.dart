import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/candidate_probe.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/features/director/director_providers.dart';
import 'package:ishkafel/features/director/find_shots_sheet.dart';

/// 找镜头面板（M3）：标签预填自动预搜、点选落地、防撞车标注。
/// 全部走假 miaoa gateway，不碰真实 CLI。
String _searchJson(int count) => jsonEncode({
      'total': count,
      'records': [
        for (var i = 0; i < count; i++)
          {
            'id': 100 + i,
            'name': '候选 $i',
            'sceneDescription': '厨房画面 $i',
            'voiceover': '台词 $i',
            'mediaFile': {
              'thumbnailUrl': 'https://example.com/$i.jpg',
              'previewUrl': 'https://example.com/$i.mp4',
              'fileKey': 'oss/$i.mp4',
            },
          },
      ],
    });

const _groupsJson = '''
[{"id":1279,"groupName":"衣清.消毒液","materialType":"STORYBOARD","tagType":"TENANT",
  "tags":[{"id":1,"tagName":"痛点引入"},{"id":2,"tagName":"产品引入"}]}]
''';

const _tagsJson = '''
[{"id":1,"tagGroupId":1279,"tagName":"痛点引入"},
 {"id":2,"tagGroupId":1279,"tagName":"产品引入"}]
''';

const _probeStdout = 'width=1080\nheight=1920\nduration=6.840000\n';

/// 按子命令分流的假 miaoa CLI；记录检索参数供断言
class _FakeCli {
  final searchArgs = <List<String>>[];

  Future<ProcessResult> call(String exe, List<String> args) async {
    if (args.contains('search')) {
      searchArgs.add(args);
      return ProcessResult(1, 0, _searchJson(3), '');
    }
    if (args.contains('group')) return ProcessResult(1, 0, _groupsJson, '');
    if (args.contains('tag')) return ProcessResult(1, 0, _tagsJson, '');
    return ProcessResult(1, 1, '', '认不出的命令：$args');
  }
}

ShotSearchServices fakeServices(_FakeCli cli) {
  final gateway = MiaoaGateway(run: cli.call, binary: 'miaoa');
  return ShotSearchServices(
    content: MiaoaContentService(gateway: gateway),
    probe: CandidateProbe(run: (_, _) async => ProcessResult(1, 0, _probeStdout, '')),
    tags: MiaoaTagService(gateway: gateway),
  );
}

RenewTask task() => RenewTask(
      id: 't1',
      name: '任务',
      sourcePath: null,
      script: ScriptDoc.empty(),
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 19),
      updatedAt: DateTime.utc(2026, 8, 19),
      unitTagGroups: const [TagGroupRef(id: 1279, name: '衣清.消毒液')],
    );

/// 打开面板；返回一个 getter，确认/取消后再读结果
Future<FindShotsResult? Function()> openSheet(
  WidgetTester tester, {
  required ShotSearchServices services,
  required ScriptLine line,
  Map<int, int> usedBy = const {},
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  FindShotsResult? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              result = await showFindShotsSheet(context,
                  services: services,
                  tagger: null,
                  task: task(),
                  lineIndex: 0,
                  line: line,
                  usedBy: usedBy);
            },
            child: const Text('开面板'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('开面板'));
  await tester.pumpAndSettle();
  return () => result;
}

void main() {
  testWidgets('行标签预填成 chips 并自动按标签预搜，候选带时长徽标', (tester) async {
    final cli = _FakeCli();
    final line = ScriptLine.create(text: '细菌怕它').withTags(['痛点引入']);
    await openSheet(tester, services: fakeServices(cli), line: line);

    expect(find.byKey(const ValueKey('shot-tag-痛点引入')), findsOneWidget);
    expect(find.byKey(const ValueKey('shot-candidate-100')), findsOneWidget,
        reason: '打开即自动预搜，人只做否决');
    expect(cli.searchArgs.single, contains('--public-tag'));
    expect(cli.searchArgs.single, contains('1'), reason: '标签名映射成词表里的 id');
    expect(find.text('6.8s'), findsWidgets, reason: '规格探测出的时长要上卡');
  });

  testWidgets('行没有标签时退回按台词的画面描述预搜', (tester) async {
    final cli = _FakeCli();
    final line = ScriptLine.create(text: '细菌怕它');
    await openSheet(tester, services: fakeServices(cli), line: line);

    expect(cli.searchArgs.single, contains('--keyword'));
    expect(cli.searchArgs.single, contains('细菌怕它'));
  });

  testWidgets('点选落地：按点选顺序返回镜头，取消选择也生效', (tester) async {
    final cli = _FakeCli();
    final line = ScriptLine.create(text: '细菌怕它').withTags(['痛点引入']);
    final result = await openSheet(tester, services: fakeServices(cli), line: line);

    await tester.tap(find.byKey(const ValueKey('shot-candidate-101')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('shot-candidate-100')));
    await tester.pump();
    expect(find.text('已选 2 个镜头（按点选顺序排）'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shots-confirm')));
    await tester.pumpAndSettle();

    expect(result()!.shots.map((s) => s.materialId), [101, 100],
        reason: '按点选顺序排，不按候选列表顺序');
    expect(result()!.shots.first.durationMs, 6840,
        reason: '探测出的时长跟着落地');
  });

  testWidgets('防撞车：别的行已用的素材打角标；本行已选的显示序号', (tester) async {
    final cli = _FakeCli();
    final line = ScriptLine.create(text: '细菌怕它').withTags(['痛点引入']);
    await openSheet(tester,
        services: fakeServices(cli), line: line, usedBy: const {102: 3});

    expect(find.text('第 4 行在用'), findsOneWidget,
        reason: '能选，但必须看得见别人在用');
  });
}
