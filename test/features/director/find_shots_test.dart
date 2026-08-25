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

ShotSearchServices _fakeServices(_FakeCli cli) {
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
  String? refVideoPath,
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
                  refVideoPath: refVideoPath,
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
  testWidgets('打开即按台词预搜，行标签自动成为约束（贴在检索上）',
      (tester) async {
    final cli = _FakeCli();
    final line = ScriptLine.create(text: '细菌怕它').withTags(['痛点引入']);
    await openSheet(tester, services: _fakeServices(cli), line: line);

    expect(find.byKey(const ValueKey('shot-tag-痛点引入')), findsOneWidget);
    expect(find.byKey(const ValueKey('shot-candidate-100')), findsOneWidget,
        reason: '打开即自动预搜，人只做否决');
    final args = cli.searchArgs.single;
    expect(args, containsAllInOrder(['--keyword', '细菌怕它']));
    expect(args, containsAllInOrder(['--by', 'voiceover']),
        reason: '默认维度是台词：参考片这句说什么就找说同类话的分镜');
    expect(args, containsAllInOrder(['--public-tag', '1']),
        reason: '标签是统一外部约束，贴在每一种维度上');
    expect(find.text('6.8s'), findsWidgets, reason: '规格探测出的时长要上卡');
  });

  testWidgets('三维度可切：画面描述维度独立输入；找相似没有目标时先提示',
      (tester) async {
    final cli = _FakeCli();
    final line = ScriptLine.create(text: '细菌怕它');
    await openSheet(tester, services: _fakeServices(cli), line: line);
    cli.searchArgs.clear();

    await tester.tap(find.byKey(const ValueKey('shots-dim-description')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('shots-keyword-desc')), '厨房喷洒');
    await tester.tap(find.byKey(const ValueKey('shots-search')));
    await tester.pumpAndSettle();
    expect(cli.searchArgs.single, containsAllInOrder(['--by', 'content']));
    expect(cli.searchArgs.single, containsAllInOrder(['--keyword', '厨房喷洒']));

    await tester.tap(find.byKey(const ValueKey('shots-dim-similar')));
    await tester.pumpAndSettle();
    expect(find.textContaining('先在下面的候选卡上点「找相似」'), findsOneWidget,
        reason: '没有查询帧时不能空转，要说清怎么发起');
  });

  testWidgets('按名称兜底：切过去自动摘掉标签，切回来标签原样还回去',
      (tester) async {
    // 主路径是拿参考镜头的描述/标签去找像的；筛不到时人会说「我知道妙啊里
    // 有那条片子」，直接按文件名捞。这时还挂着标签只会继续搜不到
    final cli = _FakeCli();
    final line = ScriptLine.create(text: '细菌怕它').withTags(['痛点引入']);
    await openSheet(tester, services: _fakeServices(cli), line: line);
    cli.searchArgs.clear();

    await tester.tap(find.byKey(const ValueKey('shots-dim-name')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('shots-keyword-name')), '滴露_植源喷雾');
    await tester.tap(find.byKey(const ValueKey('shots-search')));
    await tester.pumpAndSettle();

    final args = cli.searchArgs.single;
    expect(args, containsAllInOrder(['--by', 'name']));
    expect(args, containsAllInOrder(['--keyword', '滴露_植源喷雾']));
    expect(args.contains('--public-tag'), isFalse,
        reason: '按名字捞的时候不该再挂着标签约束');

    // 切回台词维度：刚才摘掉的标签要还回来，不能让人重新勾一遍
    cli.searchArgs.clear();
    await tester.tap(find.byKey(const ValueKey('shots-dim-voiceover')));
    await tester.pumpAndSettle();
    expect(cli.searchArgs.single, containsAllInOrder(['--public-tag', '1']));
  });

  testWidgets('筛窄了搜不到：一键清空筛选，把约束全松开重来', (tester) async {
    final cli = _FakeCli();
    final line = ScriptLine.create(text: '细菌怕它').withTags(['痛点引入']);
    await openSheet(tester, services: _fakeServices(cli), line: line);
    cli.searchArgs.clear();

    await tester.tap(find.byKey(const ValueKey('shots-clear-tags')));
    await tester.pumpAndSettle();
    expect(cli.searchArgs.single.contains('--public-tag'), isFalse,
        reason: '清空之后不该再带标签');
    expect(find.byKey(const ValueKey('shots-clear-tags')), findsNothing,
        reason: '没有勾着的标签就不该再摆一个「清空筛选」');
  });

  testWidgets('参考镜也能就地播：点缩略图上的播放键，不影响「用它去找」',
      (tester) async {
    final cli = _FakeCli();
    final line = ScriptLine.create(text: '细菌怕它')
        .withReference(LineRef(startMs: 0, endMs: 8000, cuts: const [3000]));
    await openSheet(tester,
        services: _fakeServices(cli), line: line, refVideoPath: '/v/参考片.mp4');

    // 参考镜是这个面板的主线索，每一镜都要能点开看
    expect(find.byKey(const ValueKey('shots-ref-play-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('shots-ref-play-1')), findsOneWidget);
    // 「用它的画面去找」仍在，播放键没有抢掉主操作
    expect(find.byKey(const ValueKey('shots-ref-atom-0')), findsOneWidget);
  });

  testWidgets('候选卡能就地预览：卡上有播放键，不再弹一层窗', (tester) async {
    final cli = _FakeCli();
    await openSheet(tester,
        services: _fakeServices(cli), line: ScriptLine.create(text: '细菌怕它'));

    expect(find.byKey(const ValueKey('shot-preview-100')), findsOneWidget,
        reason: '挑镜头是「看一眼再决定」的活，不该为此开关几十次弹窗');
  });

  testWidgets('标签选择器：从词表加约束标签，加完立即重搜', (tester) async {
    final cli = _FakeCli();
    final line = ScriptLine.create(text: '细菌怕它');
    await openSheet(tester, services: _fakeServices(cli), line: line);
    cli.searchArgs.clear();

    await tester.tap(find.byKey(const ValueKey('shots-pick-tags')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('产品引入'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tag-picker-ok')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('shot-tag-产品引入')), findsOneWidget,
        reason: '选好的标签进约束条');
    expect(cli.searchArgs.last, containsAllInOrder(['--public-tag', '2']),
        reason: '新标签的 id 立即生效到检索');
  });

  testWidgets('点选落地：按点选顺序返回镜头，取消选择也生效', (tester) async {
    final cli = _FakeCli();
    final line = ScriptLine.create(text: '细菌怕它').withTags(['痛点引入']);
    final result = await openSheet(tester, services: _fakeServices(cli), line: line);

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
        services: _fakeServices(cli), line: line, usedBy: const {102: 3});

    expect(find.text('第 4 行在用'), findsOneWidget,
        reason: '能选，但必须看得见别人在用');
  });
}
