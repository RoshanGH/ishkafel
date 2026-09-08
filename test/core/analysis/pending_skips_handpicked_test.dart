import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/pending_tagging.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// **人手改过的标签，补标签那条后台线不许再碰。**
///
/// 「欠着打标」原来只看「标签是不是空的」。人把标签手改成空（就是不要标签），
/// 在它眼里和「从来没打过」一模一样——于是后台默默补一份回去，人改的东西
/// 被一个他看不见的步骤盖掉了，还不问一声。
RenewTask _task(List<SemanticUnit> units) => RenewTask(
      id: 't',
      name: 't',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      units: units,
    );

void main() {
  test('标签空着、没人改过：照常补', () {
    final t = _task([
      const SemanticUnit(index: 0, startMs: 0, endMs: 1, transcript: 'a'),
    ]);

    expect(unitsPendingTagging(t), {0});
  });

  test('人手改成空：不补——那是「我就是不要标签」', () {
    final t = _task([
      const SemanticUnit(
          index: 0, startMs: 0, endMs: 1, transcript: 'a',
          tagsHandpicked: true),
    ]);

    expect(unitsPendingTagging(t), isEmpty);
  });

  test('镜头层同理（「打过标」看的是画面描述，不是标签）', () {
    final t = _task([
      const SemanticUnit(index: 0, startMs: 0, endMs: 2, transcript: 'a', shots: [
        Shot(startMs: 0, endMs: 1, tagsHandpicked: true),
        Shot(startMs: 1, endMs: 2, description: '厨房里擦台面'),
      ]),
    ]);

    expect(unitsPendingTagging(t), isEmpty);
  });

  test('只有没手改过的那个镜头欠着，才补这个单元', () {
    final t = _task([
      const SemanticUnit(index: 0, startMs: 0, endMs: 2, transcript: 'a', shots: [
        Shot(startMs: 0, endMs: 1, tagsHandpicked: true),
        Shot(startMs: 1, endMs: 2),
      ]),
    ]);

    expect(unitsPendingTagging(t), {0});
  });
}
