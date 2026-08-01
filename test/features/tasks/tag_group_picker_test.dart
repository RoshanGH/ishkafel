import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/tag_group_picker.dart';

TagGroup _g(int id, String name, {List<String> tags = const []}) => TagGroup(
      id: id,
      name: name,
      materialType: 'STORYBOARD',
      tagType: 'TENANT',
      tags: tags,
    );

/// 逼近真实规模：租户里实际有 127 个组
final _many = [
  _g(1, '画面类型', tags: ['真人口播', '产品特写', '使用演示']),
  _g(2, '脚本话术', tags: ['痛点引入', '功效演示']),
  for (var i = 3; i <= 127; i++) _g(i, '其他分组 $i', tags: ['标签$i']),
];

late TagGroupRef? picked;

Future<void> _open(WidgetTester tester, {List<TagGroup>? groups}) async {
  picked = null;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            picked = await showTagGroupPicker(context,
                title: '视觉镜头标签组', groups: groups ?? _many);
          },
          child: const Text('打开'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('tag-group-search')), text);
  await tester.pumpAndSettle();
}

void main() {
  group('边输入边过滤', () {
    testWidgets('输入组名关键字后只剩匹配项', (tester) async {
      await _open(tester);
      expect(find.text('画面类型'), findsOneWidget);

      await _type(tester, '话术');

      expect(find.text('脚本话术'), findsOneWidget);
      expect(find.text('画面类型'), findsNothing);
    });

    testWidgets('每敲一个字都重新过滤，不需要回车', (tester) async {
      await _open(tester);

      await _type(tester, '画');
      expect(find.text('画面类型'), findsOneWidget);
      await _type(tester, '画面类');
      expect(find.text('画面类型'), findsOneWidget);
      await _type(tester, '画面类型x');
      expect(find.text('画面类型'), findsNothing);
    });

    testWidgets('清空关键字后恢复全部', (tester) async {
      await _open(tester);
      await _type(tester, '话术');
      await _type(tester, '');

      expect(find.text('画面类型'), findsOneWidget);
      expect(find.text('脚本话术'), findsOneWidget);
    });
  });

  group('按标签名搜（记得住标签、记不住它在哪个组）', () {
    testWidgets('搜标签名能把所在组带出来', (tester) async {
      await _open(tester);

      await _type(tester, '产品特写');

      expect(find.text('画面类型'), findsOneWidget);
    });

    testWidgets('说明是因为哪个标签命中的', (tester) async {
      await _open(tester);

      await _type(tester, '口播');

      expect(find.textContaining('含标签：真人口播'), findsOneWidget,
          reason: '不说明理由的话，用户看到一个名字对不上的组会以为搜错了');
    });
  });

  group('选中与取消', () {
    testWidgets('点一项即选中并关闭', (tester) async {
      await _open(tester);
      await _type(tester, '话术');

      await tester.tap(find.text('脚本话术'));
      await tester.pumpAndSettle();

      expect(picked?.id, 2);
      expect(picked?.name, '脚本话术');
      expect(find.byKey(const Key('tag-group-search')), findsNothing);
    });

    testWidgets('取消返回 null', (tester) async {
      await _open(tester);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(picked, isNull);
    });
  });

  group('搜不到时给出路，而不是空白', () {
    testWidgets('提示可以改用标签名搜', (tester) async {
      await _open(tester);

      await _type(tester, '完全不存在的词');

      expect(find.textContaining('没有匹配'), findsOneWidget);
      // 搜索框的 placeholder 也含「标签名」，这里要的是空结果那段说明
      expect(find.textContaining('可以试试标签名'), findsOneWidget,
          reason: '给一条能走通的下一步，而不是让用户对着空白发呆');
    });
  });

  group('数量提示', () {
    testWidgets('告诉用户一共多少个、当前匹配多少个', (tester) async {
      await _open(tester);

      expect(find.textContaining('共 127 个标签组'), findsOneWidget,
          reason: '127 个组是当前最费劲的一步，先让用户知道规模');

      await _type(tester, '话术');
      expect(find.textContaining('匹配 1 个'), findsOneWidget);
    });
  });
}
