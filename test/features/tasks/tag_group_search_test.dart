import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/tag_group_search.dart';

TagGroup _g(int id, String name, {List<String> tags = const []}) => TagGroup(
      id: id,
      name: name,
      materialType: 'STORYBOARD',
      tagType: 'TENANT',
      tags: tags,
    );

final _groups = [
  _g(1, '画面类型', tags: ['真人口播', '产品特写', '使用演示']),
  _g(2, '脚本话术', tags: ['痛点引入', '产品引入', '功效演示']),
  _g(3, '衣清.消毒液', tags: ['除菌', '去味']),
  _g(4, 'DDSX 专用', tags: ['开箱']),
];

void main() {
  group('按组名搜', () {
    test('子串命中，不要求从头匹配', () {
      final hits = searchTagGroups(_groups, '话术');

      expect(hits.map((h) => h.group.id), [2]);
    });

    test('大小写与首尾空格都不影响', () {
      expect(searchTagGroups(_groups, '  ddsx  ').map((h) => h.group.id), [4]);
      expect(searchTagGroups(_groups, 'DDSX').map((h) => h.group.id), [4]);
    });

    test('空关键词返回全部，顺序不变', () {
      expect(searchTagGroups(_groups, '   ').map((h) => h.group.id),
          [1, 2, 3, 4]);
    });
  });

  group('按组内标签名搜（用户往往记得住标签、记不住它在哪个组）', () {
    test('标签命中时把所在组带出来', () {
      final hits = searchTagGroups(_groups, '产品特写');

      expect(hits.map((h) => h.group.id), [1]);
    });

    test('说明是因为哪个标签命中的，否则用户看不懂为什么是这个组', () {
      final hit = searchTagGroups(_groups, '特写').single;

      expect(hit.matchedTags, ['产品特写']);
    });

    test('一个词命中多个组时都返回', () {
      final hits = searchTagGroups(_groups, '演示');

      expect(hits.map((h) => h.group.id), containsAll([1, 2]));
    });

    test('同一个组里多个标签命中就都列出来', () {
      final hit = searchTagGroups(_groups, '产品').firstWhere((h) => h.group.id == 2);

      expect(hit.matchedTags, ['产品引入']);
    });
  });

  group('排序：组名命中优先于标签命中', () {
    test('搜「产品」时组名含它的排前面', () {
      final groups = [
        _g(1, '画面类型', tags: ['产品特写']),
        _g(2, '产品线', tags: ['甲']),
      ];

      final hits = searchTagGroups(groups, '产品');

      expect(hits.first.group.id, 2,
          reason: '组名直接命中比「组里有个标签含这个词」更贴近用户意图，'
              '排在后面会让人以为没搜到');
      expect(hits.first.matchedTags, isEmpty);
    });

    test('同为组名命中时保持原有顺序，不做二次排序', () {
      final groups = [_g(1, '产品甲'), _g(2, '产品乙')];

      expect(searchTagGroups(groups, '产品').map((h) => h.group.id), [1, 2]);
    });
  });

  group('搜不到', () {
    test('返回空列表，由界面负责给说明', () {
      expect(searchTagGroups(_groups, '不存在的词'), isEmpty);
    });

    test('没有标签的组也能按组名搜到', () {
      final groups = [_g(9, '空组')];

      expect(searchTagGroups(groups, '空组'), hasLength(1));
    });
  });

  group('不改动传入的列表', () {
    test('搜索返回新列表', () {
      final before = List.of(_groups);
      searchTagGroups(_groups, '产品');

      expect(_groups, equals(before));
    });
  });
}
