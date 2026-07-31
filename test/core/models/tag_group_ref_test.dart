import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/log/app_log.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';

void main() {
  group('TagGroupRef 序列化', () {
    test('toJson 同时保留 id 与名字（UI 显示名字，检索用 id）', () {
      const ref = TagGroupRef(id: 1279, name: '衣清.消毒液');
      expect(ref.toJson(), {'id': 1279, 'name': '衣清.消毒液'});
    });

    test('tryFromJson 往返一致', () {
      const ref = TagGroupRef(id: 136, name: '画面类型');
      expect(TagGroupRef.tryFromJson(ref.toJson()), ref);
    });

    test('值相等（同 id 同名即相等）', () {
      expect(const TagGroupRef(id: 1, name: 'a'),
          const TagGroupRef(id: 1, name: 'a'));
      expect(const TagGroupRef(id: 1, name: 'a').hashCode,
          const TagGroupRef(id: 1, name: 'a').hashCode);
      expect(const TagGroupRef(id: 1, name: 'a') ==
          const TagGroupRef(id: 2, name: 'a'), isFalse);
    });
  });

  group('tryFromJson 是不可信输入的边界：一律返回 null，绝不抛异常', () {
    late List<String> logs;

    setUp(() {
      logs = [];
      final previous = AppLog.sink;
      AppLog.sink = logs.add;
      addTearDown(() => AppLog.sink = previous);
    });

    test('null（旧 JSON 没有这个键）→ null 且不告警', () {
      expect(TagGroupRef.tryFromJson(null), isNull);
      expect(logs, isEmpty, reason: '旧数据缺字段是正常情况，不该刷告警');
    });

    test('不是对象 → null 并告警', () {
      expect(TagGroupRef.tryFromJson('衣清.消毒液'), isNull);
      expect(logs.join(), contains('标签组'));
    });

    test('id 类型不对 → null 并告警', () {
      expect(TagGroupRef.tryFromJson({'id': '1279', 'name': 'x'}), isNull);
      expect(logs.join(), contains('标签组'));
    });

    test('name 缺失 → null 并告警', () {
      expect(TagGroupRef.tryFromJson({'id': 1279}), isNull);
      expect(logs.join(), contains('标签组'));
    });
  });
}
