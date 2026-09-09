import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/features/director/tag_picker.dart';

/// 标签选择器：从妙啊标签体系里搜索、点选、替换行标签。
/// 词表一次拉全（--include-tags），标签 id 在确定时按涉及的组解析。
String _groupsJson() => jsonEncode([
      {
        'id': 10,
        'groupName': '话术结构',
        'materialType': 'STORYBOARD',
        'tagType': 'PUBLIC',
        'tags': [
          {'tagName': '促单'},
          {'tagName': '痛点'},
        ],
      },
      {
        'id': 20,
        'groupName': '画面场景',
        'materialType': 'STORYBOARD',
        'tagType': 'PUBLIC',
        'tags': [
          {'tagName': '厨房'},
          {'tagName': '高铁'},
          // 真机上「痛点」同时挂在植源分子库和植源动作两个组里——
          // 同名标签跨组是常态，不是脏数据
          {'tagName': '痛点'},
        ],
      },
    ]);

String _tagsJson(int groupId) => jsonEncode(groupId == 10
    ? [
        {'id': 101, 'tagName': '促单'},
        {'id': 102, 'tagName': '痛点'},
      ]
    : [
        {'id': 201, 'tagName': '厨房'},
        {'id': 202, 'tagName': '高铁'},
        {'id': 203, 'tagName': '痛点'},
      ]);

MiaoaTagService _fakeTags(List<List<String>> calls) =>
    MiaoaTagService(gateway: MiaoaGateway(run: (bin, args) async {
      calls.add(args);
      if (args.contains('group')) return ProcessResult(1, 0, _groupsJson(), '');
      final groupId = int.parse(args[args.indexOf('--group') + 1]);
      return ProcessResult(1, 0, _tagsJson(groupId), '');
    }, binary: 'miaoa'));

void main() {
  Future<Future<List<PickedTag>?>> pump(
    WidgetTester tester, {
    List<String> selected = const [],
    Set<int> preferredGroupIds = const {},
    bool onlyPreferred = false,
    List<List<String>>? calls,
  }) async {
    late Future<List<PickedTag>?> result;
    final tags = _fakeTags(calls ?? []);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () {
              result = showTagPicker(context,
                  tags: tags,
                  selected: selected,
                  preferredGroupIds: preferredGroupIds,
                  onlyPreferred: onlyPreferred);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('onlyPreferred：只给任务自己的标签组，别的组一个不露', (tester) async {
    // 审核页改标签用这一档：标签是检索键，给出任务标签组以外的词
    // 等于让人挑一个这个项目根本没素材的标签，搜完才发现是空的
    await pump(tester, preferredGroupIds: {10}, onlyPreferred: true);

    expect(find.text('话术结构'), findsOneWidget);
    expect(find.text('画面场景'), findsNothing);
    expect(find.text('厨房'), findsNothing);
  });

  testWidgets('词表按组铺开，点选后确定返回带 id 的标签', (tester) async {
    final resultFuture = await pump(tester);

    expect(find.text('话术结构'), findsOneWidget);
    expect(find.text('画面场景'), findsOneWidget);
    await tester.tap(find.text('促单'));
    await tester.tap(find.text('厨房'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tag-picker-ok')));
    await tester.pumpAndSettle();

    final picked = await resultFuture;
    expect(picked, isNotNull);
    expect({for (final t in picked!) t.name: t.id}, {'促单': 101, '厨房': 201});
  });

  /// 2026-09-09 真机：U1·S7 的标签原本 4 个，进「改标签」原样确定一遍之后
  /// 变成 5 个——「痛点」写了两遍。原因是返回值按「组序 + 组内序」铺开，
  /// 而同一个标签名同时挂在两个组里，就被铺了两次。
  ///
  /// 后果不只是难看：这份 tags 是检索键，也是界面上展示的那一排，
  /// 每过一次「改标签」就多一份，改几次就是一串重复。
  testWidgets('同名标签挂在两个组里：只返回一次，不重复', (tester) async {
    final resultFuture = await pump(tester);

    // 「痛点」在话术结构和画面场景两个组里各有一个格子，点其中一个即可
    await tester.tap(find.text('痛点').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tag-picker-ok')));
    await tester.pumpAndSettle();

    final picked = await resultFuture;
    expect(picked!.map((t) => t.name).toList(), ['痛点'],
        reason: '同一个名字铺两遍的话，标签会一次比一次多');
  });

  testWidgets('搜索过滤标签；已选的先带勾、可取消（替换 = 取消旧的选新的）',
      (tester) async {
    final resultFuture = await pump(tester, selected: ['促单']);

    await tester.enterText(
        find.byKey(const ValueKey('tag-picker-search')), '厨');
    await tester.pumpAndSettle();
    expect(find.text('厨房'), findsOneWidget);
    expect(find.text('高铁'), findsNothing, reason: '搜索要把没命中的藏起来');

    await tester.tap(find.text('厨房'));
    await tester.enterText(
        find.byKey(const ValueKey('tag-picker-search')), '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('促单')); // 取消预选的「促单」
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tag-picker-ok')));
    await tester.pumpAndSettle();

    final picked = await resultFuture;
    expect(picked!.map((t) => t.name).toList(), ['厨房']);
  });

  testWidgets('取消返回 null，不动行标签', (tester) async {
    final resultFuture = await pump(tester, selected: ['促单']);
    await tester.tap(find.byKey(const ValueKey('tag-picker-cancel')));
    await tester.pumpAndSettle();
    expect(await resultFuture, isNull);
  });
}
