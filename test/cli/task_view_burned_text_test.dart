import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_view.dart';
import 'package:ishkafel/core/agent_skill/agent_skill_doc.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';

/// 手册教 Agent 用一句 jq 去查「哪几条素材画面上烧着字」。那句 jq 指的
/// 字段和路径**必须真的存在**——不然 Agent 照着做只会得到空结果，
/// 而空结果看起来正好像「都干净」。真机上就差点这样：字段压根没投影出来。
void main() {
  RenewTask task(List<PickedMaterial> picked) => RenewTask(
        id: 't1',
        name: 'n',
        sourcePath: '/v/a.mp4',
        createdAt: DateTime.utc(2026, 8, 29),
        status: RenewTaskStatus.ready,
        updatedAt: DateTime.utc(2026, 8, 29),
        pickedMaterials: picked,
      );

  test('已选素材要带上烧录文字——没有它手册那句 jq 永远查不到东西', () {
    final json = taskToJson(task(const [
      PickedMaterial(id: 11, name: 'a', burnedText: ['冰冰凉凉的好舒服呀']),
    ]));
    final items = (json['pickedMaterials'] as Map)['items'] as List;
    expect((items.single as Map)['burnedText'], ['冰冰凉凉的好舒服呀']);
  });

  test('没查过时整个键不出现——空数组会被读成「画面干净」', () {
    final json = taskToJson(task(const [PickedMaterial(id: 11, name: 'a')]));
    final items = (json['pickedMaterials'] as Map)['items'] as List;
    expect((items.single as Map).containsKey('burnedText'), isFalse);
  });

  test('查过且干净：空数组，和「没查过」分得开', () {
    final json = taskToJson(task(const [
      PickedMaterial(id: 11, name: 'a', burnedText: []),
    ]));
    final items = (json['pickedMaterials'] as Map)['items'] as List;
    expect((items.single as Map)['burnedText'], isEmpty);
  });

  test('产品露出的品牌也要报出来——它决定这条素材能不能用', () {
    final json = taskToJson(task(const [
      PickedMaterial(id: 11, name: 'a', burnedText: [], productBrand: '若也 Rove'),
    ]));
    final items = (json['pickedMaterials'] as Map)['items'] as List;
    expect((items.single as Map)['productBrand'], '若也 Rove');
  });

  test('纯场景镜头没有产品：整个键不出现', () {
    final json = taskToJson(task(const [
      PickedMaterial(id: 11, name: 'a', burnedText: []),
    ]));
    final items = (json['pickedMaterials'] as Map)['items'] as List;
    expect((items.single as Map).containsKey('productBrand'), isFalse);
  });

  test('看了几帧也要报出来——1 帧的结论没有 3 帧硬', () {
    final json = taskToJson(task(const [
      PickedMaterial(id: 11, name: 'a', burnedText: [], framesSeen: 3),
    ]));
    final items = (json['pickedMaterials'] as Map)['items'] as List;
    expect((items.single as Map)['framesSeen'], 3);
  });

  /// 同一处已经漏过两次字段（burnedText、framesSeen）：存进去了、
  /// 但 `task --json` 不报，Agent 照手册查永远是空——而空看起来正好像
  /// 「没问题」。这道测试按**已选素材上所有画面自查字段**来对，
  /// 以后再加一个也跑不掉。
  test('画面自查的每个字段都要投影出去，一个都不许漏', () {
    const full = PickedMaterial(
      id: 11,
      name: 'a',
      durationMs: 1000,
      burnedText: ['字'],
      productBrand: '滴露',
      framesSeen: 3,
    );
    final item = ((taskToJson(task(const [full]))['pickedMaterials']
        as Map)['items'] as List).single as Map;
    for (final key in full.toJson().keys) {
      expect(item.containsKey(key), isTrue,
          reason: '已选素材存了 $key 却没在 task --json 里报出来');
    }
  });

  /// 手册教 Agent 用 `.units[].shots[].productBrand` 查原片是什么牌子。
  /// 这处已经漏过两次字段（burnedText、framesSeen 各一次）——存进去了、
  /// 但不报出来，Agent 照手册查永远是空，而空看起来正好像「没问题」。
  test('原片每一镜露的是什么牌子也要报出来', () {
    final json = taskToJson(RenewTask(
      id: 't1',
      name: 'n',
      sourcePath: '/v/a.mp4',
      createdAt: DateTime.utc(2026, 8, 29),
      updatedAt: DateTime.utc(2026, 8, 29),
      status: RenewTaskStatus.ready,
      units: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 1000,
          transcript: 'a',
          shots: [Shot(startMs: 0, endMs: 1000, productBrand: '滴露')],
        ),
      ],
    ));
    final shots = ((json['units'] as List).single as Map)['shots'] as List;
    expect((shots.single as Map)['productBrand'], '滴露');
  });

  test('手册里那句 jq 的路径要和真实输出对得上', () {
    // 真实结构是 pickedMaterials.items[]，不是 pickedMaterials[]
    expect(agentSkillMarkdown, contains('.pickedMaterials.items[]'));
    expect(agentSkillMarkdown, isNot(contains('.pickedMaterials[]')));
  });
}
