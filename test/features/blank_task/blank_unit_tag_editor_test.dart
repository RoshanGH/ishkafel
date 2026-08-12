import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/tag_vocabulary.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/features/blank_task/blank_unit_tag_editor.dart';

class _FakeVocabulary implements TagVocabularySource {
  final List<String> words;
  final Object? error;
  const _FakeVocabulary(this.words, {this.error});

  @override
  Future<List<String>> vocabularyOf(int groupId) async {
    if (error != null) throw error!;
    return words;
  }
}

/// 给分子打标签。
///
/// 核心约束：**只能从词表里选，不许手打**。手打的标签检索时一个都命中不了，
/// 而用户打完字看不出任何异常，要等搜不出素材才发现。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    List<String> tags = const [],
    List<String> words = const ['厨房情景', '实拍', '冰箱收纳'],
    Object? error,
    List<TagGroupRef> groups = const [TagGroupRef(id: 1, name: '组甲')],
    ValueChanged<List<String>>? onChanged,
  }) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: BlankUnitTagEditor(
            unitIndex: 0,
            tags: tags,
            tagGroups: groups,
            vocabulary: _FakeVocabulary(words, error: error),
            onChanged: onChanged ?? (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('把词表里的标签摆出来供选择，没有任何可以手打的输入框', (tester) async {
    await pump(tester);
    expect(find.text('厨房情景'), findsOneWidget);
    expect(find.text('实拍'), findsOneWidget);
    expect(find.byType(TextField), findsNothing,
        reason: '能手打就一定会有人打出词表外的词，然后搜不出东西还不知道为什么');
  });

  testWidgets('点一下选中、再点一下取消，都把新列表交出去', (tester) async {
    final changes = <List<String>>[];
    await pump(tester, onChanged: changes.add);
    await tester.tap(find.text('实拍'));
    expect(changes.last, ['实拍']);

    await pump(tester, tags: const ['实拍'], onChanged: changes.add);
    await tester.tap(find.text('实拍'));
    expect(changes.last, isEmpty);
  });

  testWidgets('一个标签组都没有时说清多半是选错了企业或项目', (tester) async {
    await pump(tester, groups: const []);
    expect(find.textContaining('多半是选错了企业或项目'), findsOneWidget);
  });

  testWidgets('词表拉不到时报错并给重试——不能变成一个空白面板', (tester) async {
    // 空白面板会让用户以为这个标签组本来就是空的
    await pump(tester, error: StateError('connection refused'));
    expect(find.textContaining('标签读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('标签就是检索键这件事要写在面上', (tester) async {
    await pump(tester);
    expect(find.textContaining('搜素材的检索键'), findsOneWidget);
  });
}
