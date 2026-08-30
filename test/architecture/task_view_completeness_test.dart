import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_view.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/cli/script_view.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// **存进去了、但 `task --json` 不报**——同一个坑三天里栽了三次
/// （burnedText、framesSeen、shots 的 productBrand）。
///
/// 后果一致而且隐蔽：Agent 照手册那句 jq 查永远拿到空，
/// 而**空看起来正好像「没问题」**——一条烧着别家字幕、露着竞品的素材
/// 就这么静默进了片子。
///
/// 这道测试按模型自己的 `toJson()` 来对：模型存了什么，`task --json`
/// 就得报什么。以后再加字段也跑不掉，不用记得回来补测试。
void main() {
  _scriptViewTests();
  Map _shotJson(Shot shot) {
    final json = taskToJson(_task(shots: [shot]));
    final units = json['units'] as List;
    return ((units.single as Map)['shots'] as List).single as Map;
  }

  Map _pickedJson(PickedMaterial m) {
    final json = taskToJson(_task(picked: [m]));
    return ((json['pickedMaterials'] as Map)['items'] as List).single as Map;
  }

  test('视觉镜头存下来的每个字段都要报出来', () {
    const shot = Shot(
      startMs: 0,
      endMs: 1000,
      tags: ['痛点'],
      description: '一句话',
      productBrand: '滴露',
    );
    final reported = _shotJson(shot);
    for (final key in shot.toJson().keys) {
      // trace/boundaryTrace 是给「标签为什么是这个」留痕用的大对象，
      // 命令行不报是有意的——它们有专门的看法（tag-trace）
      if (key == 'trace' || key == 'boundaryTrace' || key == 'tagsStale') {
        continue;
      }
      expect(reported.containsKey(key), isTrue,
          reason: '视觉镜头存了 $key 却没在 task --json 里报出来。'
              'Agent 照手册查会拿到空，而空看起来像「没问题」');
    }
  });

  test('已选素材存下来的每个字段都要报出来', () {
    const m = PickedMaterial(
      id: 11,
      name: 'a',
      voiceover: '台词',
      sceneDescription: '画面',
      durationMs: 1000,
      burnedText: ['字'],
      productBrand: '滴露',
      framesSeen: 3,
    );
    final reported = _pickedJson(m);
    for (final key in m.toJson().keys) {
      // 首帧图的本地路径是界面自己的事，命令行报出去没有用处
      if (key == 'thumbPath') continue;
      expect(reported.containsKey(key), isTrue,
          reason: '已选素材存了 $key 却没在 task --json 里报出来');
    }
  });
}

RenewTask _task({List<Shot> shots = const [], List<PickedMaterial> picked = const []}) =>
    RenewTask(
      id: 't1',
      name: 'n',
      sourcePath: '/v/a.mp4',
      createdAt: DateTime.utc(2026, 8, 29),
      updatedAt: DateTime.utc(2026, 8, 29),
      status: RenewTaskStatus.ready,
      pickedMaterials: picked,
      units: [
        SemanticUnit(
            index: 0, startMs: 0, endMs: 1000, transcript: 'a', shots: shots),
      ],
    );

/// 脚本成片那条线同理：`LineShot` 存了什么，`script show --json` 就得报
/// 什么。这一处一开始整条缺席（`burnedText` / `productBrand` / `framesSeen`
/// 三个词在整份输出里零命中），而手册教 Agent 用 jq 去查它们。
void _scriptViewTests() {
  test('脚本成片的镜头，存下来的画面自查字段都要报出来', () {
    const shot = LineShot(
      materialId: 7,
      name: 'm',
      sceneDescription: '画面',
      durationMs: 20000,
      burnedText: ['已售罄'],
      productBrand: '滴露',
      framesSeen: 3,
      trimStartMs: 100,
    );
    final json = scriptLineJson(
      ScriptDoc([
        ScriptLine(id: 'l1', text: '一句', shots: [shot]),
      ]),
      0,
    );
    final reported = (json['shots'] as List).single as Map;
    for (final key in ['burnedText', 'productBrand', 'framesSeen']) {
      expect(reported.containsKey(key), isTrue,
          reason: '镜头存了 $key 却没在 script show --json 里报出来。'
              'Agent 照手册那句 jq 查会拿到空——而空看起来像「没问题」');
    }
  });
}
