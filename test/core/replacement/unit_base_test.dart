import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/replacement/unit_base.dart';

SemanticUnit _unit({
  int index = 0,
  int startMs = 1000,
  int endMs = 5000,
  bool hasSource = true,
}) =>
    SemanticUnit(
      uid: 'u$index',
      index: index,
      startMs: startMs,
      endMs: endMs,
      transcript: '一句台词',
      hasSource: hasSource,
    );

/// 素材落地表：id → 本地文件
String? _pathOf(int id) => const {7: '/m/7.mp4', 9: '/m/9.mp4'}[id];
int? _durationOf(int id) => const {7: 6500, 9: 3200}[id];

void main() {
  group('底片取自原片', () {
    test('普通单元：底片就是原片的那一段', () {
      final base = baseOf(
        unit: _unit(),
        replacement: UnitReplacement.keepOriginal(),
        sourcePath: '/v/src.mp4',
        pathOf: _pathOf,
      );

      expect(base?.path, '/v/src.mp4');
      expect(base?.startMs, 1000);
      expect(base?.endMs, 5000);
      expect(base?.isOriginal, isTrue);
      expect(base?.candidateId, isNull);
    });

    test('镜头替换不动底片——它换的是底片上的某一刀', () {
      final base = baseOf(
        unit: _unit(),
        replacement: UnitReplacement.perShot({
          0: [7]
        }),
        sourcePath: '/v/src.mp4',
        pathOf: _pathOf,
      );

      expect(base?.path, '/v/src.mp4');
      expect(base?.isOriginal, isTrue);
    });
  });

  group('底片是挑来的素材', () {
    test('整体替换 = 给这一段换一张底片', () {
      final base = baseOf(
        unit: _unit(),
        replacement: UnitReplacement.whole([7]),
        sourcePath: '/v/src.mp4',
        pathOf: _pathOf,
        durationOf: _durationOf,
      );

      expect(base?.path, '/m/7.mp4');
      expect(base?.candidateId, 7);
      expect(base?.isOriginal, isFalse);
    });

    test('用素材自己的一整条：从 0 到它的时长', () {
      final base = baseOf(
        unit: _unit(),
        replacement: UnitReplacement.whole([7]),
        sourcePath: '/v/src.mp4',
        pathOf: _pathOf,
        durationOf: _durationOf,
      );

      expect(base?.startMs, 0);
      expect(base?.endMs, 6500, reason: '时长跟素材走，这是整体替换的既有规则');
    });

    test('素材时长探不出来：退回坑位时长，不编造一个数', () {
      final base = baseOf(
        unit: _unit(),
        replacement: UnitReplacement.whole([7]),
        sourcePath: '/v/src.mp4',
        pathOf: _pathOf,
      );

      expect(base?.endMs, 4000, reason: '单元 1000~5000 = 4000ms');
    });

    test('选了好几条：默认用 ★ 预览那条', () {
      final base = baseOf(
        unit: _unit(),
        replacement: UnitReplacement.whole([7, 9], previewId: 9),
        sourcePath: '/v/src.mp4',
        pathOf: _pathOf,
        durationOf: _durationOf,
      );

      expect(base?.candidateId, 9);
    });

    test('导出某一条变体：由调用方指定这一条用哪张底片', () {
      final base = baseOf(
        unit: _unit(),
        replacement: UnitReplacement.whole([7, 9], previewId: 9),
        sourcePath: '/v/src.mp4',
        wholeCandidateId: 7,
        pathOf: _pathOf,
        durationOf: _durationOf,
      );

      expect(base?.candidateId, 7,
          reason: '同一个单元在不同变体里用不同底片，预览那条只是默认值');
    });

    test('手加的单元填进来的素材，同样是底片', () {
      final base = baseOf(
        unit: _unit(hasSource: false),
        replacement: UnitReplacement.whole([7]),
        sourcePath: '/v/src.mp4',
        pathOf: _pathOf,
        durationOf: _durationOf,
      );

      expect(base?.path, '/m/7.mp4');
      expect(base?.isOriginal, isFalse);
    });
  });

  group('没有底片', () {
    test('手加的单元还没挑素材：这一段真的没东西可放', () {
      final base = baseOf(
        unit: _unit(hasSource: false),
        replacement: UnitReplacement.keepOriginal(),
        sourcePath: '/v/src.mp4',
        pathOf: _pathOf,
      );

      expect(base, isNull);
    });

    test('空白任务没有原片、又没挑素材', () {
      final base = baseOf(
        unit: _unit(hasSource: false),
        replacement: UnitReplacement.keepOriginal(),
        sourcePath: null,
        pathOf: _pathOf,
      );

      expect(base, isNull);
    });

    test('整体替换空着（还没选）：等于没换，底片还是原片', () {
      final base = baseOf(
        unit: _unit(),
        replacement: UnitReplacement.whole(const []),
        sourcePath: '/v/src.mp4',
        pathOf: _pathOf,
      );

      expect(base?.path, '/v/src.mp4');
    });
  });

  test('选了素材但文件还没落地：退回原片——今天就是这个行为', () {
    final base = baseOf(
      unit: _unit(),
      replacement: UnitReplacement.whole([42]),
      sourcePath: '/v/src.mp4',
      pathOf: _pathOf,
    );

    expect(base?.path, '/v/src.mp4',
        reason: '素材还在下载中时预览照旧放原片，不是黑屏');
  });

  test('选了素材、文件没落地、这个单元又没有原片：还是没东西可放', () {
    final base = baseOf(
      unit: _unit(hasSource: false),
      replacement: UnitReplacement.whole([42]),
      sourcePath: '/v/src.mp4',
      pathOf: _pathOf,
    );

    expect(base, isNull);
  });

  test('时长是算出来的，不用再各处减一遍', () {
    final base = baseOf(
      unit: _unit(startMs: 2000, endMs: 7500),
      replacement: UnitReplacement.keepOriginal(),
      sourcePath: '/v/src.mp4',
      pathOf: _pathOf,
    );

    expect(base?.durationMs, 5500);
  });

  group('决策层：不碰文件，导出侧也用它', () {
    test('整体替换 → 底片是那条素材', () {
      expect(
        baseChoiceOf(
            unit: _unit(), replacement: UnitReplacement.whole([7])),
        const MaterialBase(7),
      );
    });

    test('这一条变体用哪张底片由调用方指定', () {
      expect(
        baseChoiceOf(
          unit: _unit(),
          replacement: UnitReplacement.whole([7, 9], previewId: 9),
          wholeCandidateId: 7,
        ),
        const MaterialBase(7),
      );
    });

    test('保留原片 → 底片是原片那一段', () {
      expect(
        baseChoiceOf(
            unit: _unit(), replacement: UnitReplacement.keepOriginal()),
        const OriginalBase(1000, 5000),
      );
    });

    test('镜头替换 → 底片还是原片：它换的是底片上的某一刀', () {
      expect(
        baseChoiceOf(
            unit: _unit(),
            replacement: UnitReplacement.perShot({
              0: [7]
            })),
        const OriginalBase(1000, 5000),
      );
    });

    test('手加的单元没挑素材 → 没有底片', () {
      expect(
        baseChoiceOf(
            unit: _unit(hasSource: false),
            replacement: UnitReplacement.keepOriginal()),
        const NoBase(),
      );
    });

    test('整条任务没有原片、又没挑素材 → 没有底片', () {
      expect(
        baseChoiceOf(
            unit: _unit(),
            replacement: UnitReplacement.keepOriginal(),
            hasOriginal: false),
        const NoBase(),
      );
    });

    test('决策不碰文件系统：素材在不在盘上都给同一个答案', () {
      // 42 不在 _pathOf 里（没落地），决策层照样说「底片是 42」——
      // 「文件还没下下来」是解析层的事，不是决策的事
      expect(
        baseChoiceOf(
            unit: _unit(), replacement: UnitReplacement.whole([42])),
        const MaterialBase(42),
      );
    });
  });

  group('底片被固定之后', () {
    SemanticUnit pinned() => SemanticUnit(
          uid: 'u0',
          index: 0,
          startMs: 1000,
          endMs: 5000,
          transcript: '一句台词',
          baseCandidateId: 7,
        );

    test('固定过就是它，压过整体替换的候选', () {
      expect(
        baseChoiceOf(
            unit: pinned(), replacement: UnitReplacement.whole([9])),
        const MaterialBase(7),
        reason: '镜头是按 7 切出来的，改成 9 那些切点就全指错地方',
      );
    });

    test('也压过调用方指定的那一条——固定就是固定', () {
      expect(
        baseChoiceOf(
          unit: pinned(),
          replacement: UnitReplacement.whole([7, 9]),
          wholeCandidateId: 9,
        ),
        const MaterialBase(7),
      );
    });

    test('连保留原片都压过：它的画面已经不来自原片了', () {
      expect(
        baseChoiceOf(
            unit: pinned(), replacement: UnitReplacement.keepOriginal()),
        const MaterialBase(7),
      );
    });

    test('镜头替换不动底片：换的是底片上的某一刀', () {
      expect(
        baseChoiceOf(
            unit: pinned(),
            replacement: UnitReplacement.perShot({
              1: [9]
            })),
        const MaterialBase(7),
      );
    });

    test('解析成路径时同样认它', () {
      final base = baseOf(
        unit: pinned(),
        replacement: UnitReplacement.keepOriginal(),
        sourcePath: '/v/src.mp4',
        pathOf: _pathOf,
        durationOf: _durationOf,
      );

      expect(base?.path, '/m/7.mp4');
      expect(base?.candidateId, 7);
    });
  });
}