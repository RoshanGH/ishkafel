import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/candidate_context.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 挑素材时给调用方的**上下文**。
///
/// 只给「这个镜头 2.8 秒、标签是厨房清洁」，很容易挑出**每一个都合规、连起来
/// 很怪**的组合——人挑的时候是有整体感的：知道这里是开箱、那里是演示效果。
///
/// 软件的职责是把这些**事实**开放出来。「要和前后顺不顺」「同批微调版要挑
/// 差异大的」是方法论，写在给 Agent 的 skill 里，不硬编码进这里
/// （见 spec 第一节）。
void main() {
  RenewTask taskWith({List<UnitReplacement>? replacements}) => RenewTask(
        id: 't',
        name: 'n',
        sourcePath: '/tmp/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        units: [
          SemanticUnit(
            uid: 'u0',
            index: 0,
            startMs: 0,
            endMs: 6000,
            transcript: '这个东西能把衣服洗干净',
            tags: const ['主卖点'],
            shots: const [
              Shot(startMs: 0, endMs: 2000, description: '手拿瓶子'),
              Shot(startMs: 2000, endMs: 4000, description: '倒进洗衣机'),
              Shot(startMs: 4000, endMs: 6000, description: '衣服特写'),
            ],
          ),
        ],
        // 测试里的单元身份统一用 'u0'/'u1'…，方案按位置铺到它们身上
        replacementsByUid: {
          for (var i = 0; i < (replacements ?? const []).length; i++)
            'u$i': replacements![i],
        },
      );

  test('带上本单元的台词与标签——那是这一段在讲什么', () {
    final ctx = shotContext(task: taskWith(), unitIndex: 0, shotIndex: 1);
    expect(ctx['unitTranscript'], '这个东西能把衣服洗干净');
    expect(ctx['unitTags'], ['主卖点']);
  });

  test('带上相邻镜头的画面描述——避免连起来很怪', () {
    final ctx = shotContext(task: taskWith(), unitIndex: 0, shotIndex: 1);
    expect((ctx['previous'] as Map)['description'], '手拿瓶子');
    expect((ctx['next'] as Map)['description'], '衣服特写');
  });

  test('相邻镜头已经挑过素材的话说出来——组方案时要避开雷同', () {
    final ctx = shotContext(
      task: taskWith(replacements: [
        UnitReplacement.perShot(const {
          0: [101, 102]
        }),
      ]),
      unitIndex: 0,
      shotIndex: 1,
    );
    expect((ctx['previous'] as Map)['pickedMaterialIds'], [101, 102]);
  });

  test('没挑过就是空列表，不是 null——调用方不用做两种判断', () {
    final ctx = shotContext(task: taskWith(), unitIndex: 0, shotIndex: 1);
    expect((ctx['previous'] as Map)['pickedMaterialIds'], isEmpty);
  });

  test('首尾镜头没有前/后，给 null 而不是编一个', () {
    final first = shotContext(task: taskWith(), unitIndex: 0, shotIndex: 0);
    expect(first['previous'], isNull);
    final last = shotContext(task: taskWith(), unitIndex: 0, shotIndex: 2);
    expect(last['next'], isNull);
  });

  test('这个镜头本身的坑位长度要给——变速倍率靠它算', () {
    final ctx = shotContext(task: taskWith(), unitIndex: 0, shotIndex: 1);
    expect(ctx['slotMs'], 2000);
    expect(ctx['description'], '倒进洗衣机');
  });
}
