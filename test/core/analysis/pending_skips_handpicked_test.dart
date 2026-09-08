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

  group('手加的台词语义单元：不排进自动打标', () {
    // 2026-09-08 真机：每次打开任务，手加的 U1 都会被再打一次标——它没有
    // 台词、没有镜头、原片里也没有它，模型没有任何东西可以据以打标，
    // 于是每次都白烧一次 AI 调用，返回的还永远是空。
    //
    // 它的标签本来就是人手填的（withHandpickedTags），不该走自动这条路。
    RenewTask taskWith(List<SemanticUnit> units) => RenewTask(
          id: 't',
          name: 'n',
          sourcePath: '/v/src.mp4',
          status: RenewTaskStatus.ready,
          units: units,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        );

    test('没有原片来源的单元不算欠打标', () {
      final task = taskWith(const [
        SemanticUnit(
            index: 0,
            startMs: 96233,
            endMs: 106233,
            transcript: '',
            hasSource: false),
      ]);

      expect(unitsPendingTagging(task), isEmpty,
          reason: '它没有台词也没有画面，打标只会返回空——'
              '每打开一次任务就白烧一次 AI 调用');
    });

    test('原片里的单元照旧欠着', () {
      final task = taskWith(const [
        SemanticUnit(index: 0, startMs: 0, endMs: 1000, transcript: '有台词'),
      ]);

      expect(unitsPendingTagging(task), contains(0));
    });
  });
}
