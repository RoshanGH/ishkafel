import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/tag_id_resolver.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';

class _Tags implements MiaoaTagService {
  int calls = 0;
  bool broken;
  _Tags({this.broken = true});

  @override
  Future<List<TagInfo>> listTags(int groupId) async {
    calls++;
    if (broken) throw MiaoaException('读不到');
    return const [TagInfo(id: 1, name: '灶台')];
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('拉失败后不会自己重来——这正是「退出去重进才恢复」的原因', () async {
    final service = _Tags();
    final resolver = TagIdResolver(service);

    await resolver.loadAll([978]);
    await resolver.loadAll([978]);

    expect(resolver.loadFailure, isNotNull);
    expect(service.calls, 2, reason: '未成功时会重试，但没人再调它');
  });

  test('reset 之后能真的重新拉到', () async {
    final service = _Tags();
    final resolver = TagIdResolver(service);
    await resolver.loadAll([978]);
    expect(resolver.loaded, isFalse);

    service.broken = false;
    resolver.reset();
    await resolver.loadAll([978]);

    expect(resolver.loaded, isTrue);
    expect(resolver.loadFailure, isNull);
    expect(resolver.idIn('灶台', 978), 1);
  });

  test('成功之后 reset 再拉，结果照样对——不会把表清空就不管了', () async {
    final service = _Tags(broken: false);
    final resolver = TagIdResolver(service);
    await resolver.loadAll([978]);

    resolver.reset();
    expect(resolver.loaded, isFalse, reason: 'reset 之后就是「还没拉过」');
    await resolver.loadAll([978]);

    expect(resolver.idIn('灶台', 978), 1);
  });
}
