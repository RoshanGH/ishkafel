import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/features/picking/tag_hit_probe.dart';

class _Content implements MiaoaContentService {
  final calls = <({List<int> tags, List<int> projects, int pageSize})>[];

  /// 促单（21）一条都没有，辅助卖点（22）有 4 条，30 号标签查询会失败
  @override
  Future<CandidatePage> searchByTags({
    required List<int> tagIds,
    String mode = 'or',
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 20,
  }) async {
    calls.add((tags: tagIds, projects: projectIds, pageSize: pageSize));
    if (tagIds.single == 30) throw Exception('接口挂了');
    return CandidatePage(
      items: const [],
      total: switch (tagIds.single) { 21 => 0, 22 => 4, _ => 1 },
      skipped: 0,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('逐个标签数条数，带上项目', () async {
    final content = _Content();

    final hits = await TagHitProbe(content).probe(
      tags: const [(name: '促单', id: 21), (name: '辅助卖点', id: 22)],
      projectIds: const [104],
    );

    expect(hits.map((h) => (h.name, h.count)), [('促单', 0), ('辅助卖点', 4)],
        reason: '用户要判断的是「我标签打错了，还是库里这一类没入库」，'
            '摊开成每个标签各有多少条才看得出来');
    expect(content.calls.every((c) => c.projects.contains(104)), isTrue);
  });

  test('只要总数，不把二十条素材连带拉回来', () async {
    final content = _Content();

    await TagHitProbe(content).probe(tags: const [(name: '促单', id: 21)]);

    expect(content.calls.single.pageSize, 1);
  });

  test('一个标签查不到不牵连其余——其余的数字照样有用', () async {
    final hits = await TagHitProbe(_Content()).probe(
      tags: const [(name: '坏的', id: 30), (name: '辅助卖点', id: 22)],
    );

    expect(hits.first.count, isNull, reason: 'null 让界面写「查不到」而不是「0 条」');
    expect(hits.last.count, 4);
  });

  test('同一个标签只数一次——来回切换单元不该反复起子进程', () async {
    final content = _Content();
    final probe = TagHitProbe(content);

    await probe.probe(tags: const [(name: '促单', id: 21)]);
    await probe.probe(tags: const [(name: '促单', id: 21)]);

    expect(content.calls, hasLength(1));
  });

  test('换了项目要重数：同一个标签在别的项目下是另一个数字', () async {
    final content = _Content();
    final probe = TagHitProbe(content);

    await probe.probe(
        tags: const [(name: '促单', id: 21)], projectIds: const [104]);
    await probe.probe(
        tags: const [(name: '促单', id: 21)], projectIds: const [139]);

    expect(content.calls, hasLength(2));
  });
}
