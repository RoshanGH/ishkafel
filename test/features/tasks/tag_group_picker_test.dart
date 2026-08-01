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

late List<TagGroupRef>? picked;

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

  group('多选', () {
    testWidgets('勾选多个后确定，一次带回全部', (tester) async {
      await _open(tester);

      await tester.tap(find.text('画面类型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('脚本话术'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag-group-confirm')));
      await tester.pumpAndSettle();

      expect(picked?.map((g) => g.id), [1, 2],
          reason: '一个镜头本来就该同时有几个维度的标签，'
              '只能选一个组等于只能打一个维度');
    });

    testWidgets('勾选后不关闭，可以接着搜下一个组', (tester) async {
      await _open(tester);

      await tester.tap(find.text('画面类型'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tag-group-search')), findsOneWidget,
          reason: '选一个就关掉的话，选第二个组要重新打开、重新搜一遍');
      expect(find.textContaining('已选 1 个'), findsOneWidget);
    });

    testWidgets('再点一次取消勾选', (tester) async {
      await _open(tester);

      await tester.tap(find.text('画面类型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('画面类型'));
      await tester.pumpAndSettle();

      expect(find.textContaining('已选'), findsNothing);
    });

    testWidgets('搜索过滤不影响已经勾上的（换个词搜时选中态要留着）', (tester) async {
      await _open(tester);

      await tester.tap(find.text('画面类型'));
      await tester.pumpAndSettle();
      await _type(tester, '话术');
      await tester.tap(find.text('脚本话术'));
      await tester.pumpAndSettle();
      await _type(tester, '');
      await tester.tap(find.byKey(const Key('tag-group-confirm')));
      await tester.pumpAndSettle();

      expect(picked?.map((g) => g.id), [1, 2],
          reason: '过滤会重建列表，用对象而不是 id 记选中就会在这里丢');
    });

    testWidgets('返回顺序按列表原顺序，与点选先后无关', (tester) async {
      await _open(tester);

      await tester.tap(find.text('脚本话术')); // 先点第 2 个
      await tester.pumpAndSettle();
      await tester.tap(find.text('画面类型'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag-group-confirm')));
      await tester.pumpAndSettle();

      expect(picked?.map((g) => g.id), [1, 2],
          reason: '顺序不稳定会让「已选」区域每次看起来都不一样');
    });

    testWidgets('一个都没勾时确定按钮禁用', (tester) async {
      await _open(tester);

      final btn = tester.widget<FilledButton>(
          find.byKey(const Key('tag-group-confirm')));

      expect(btn.onPressed, isNull, reason: '确认一个空选择等于清空，没有意义');
    });

    testWidgets('带着已选进来时保持勾选', (tester) async {
      picked = null;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showTagGroupPicker(context,
                    title: '视觉镜头标签组',
                    groups: _many,
                    selected: const [TagGroupRef(id: 1, name: '画面类型')]);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.textContaining('已选 1 个'), findsOneWidget);
    });

    testWidgets('取消返回 null（区别于清空后确认）', (tester) async {
      await _open(tester);
      await tester.tap(find.text('画面类型'));
      await tester.pumpAndSettle();

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
