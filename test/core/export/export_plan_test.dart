import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// U1 = 0~2000（S1 0~1000、S2 1000~2000），U2 = 2000~5000（S1 整段）
List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: 'U1',
        shots: [
          Shot(startMs: 0, endMs: 1000),
          Shot(startMs: 1000, endMs: 2000),
        ],
      ),
      SemanticUnit(
        index: 1,
        startMs: 2000,
        endMs: 5000,
        transcript: 'U2',
        shots: [Shot(startMs: 2000, endMs: 5000)],
      ),
    ];

List<ExportCombination> _enumerate(List<UnitReplacement> replacements,
        {int limit = ReplacementPlan.maxCombinations}) =>
    ExportPlanner.enumerate(
        units: _units(), replacements: replacements, limit: limit);

/// 一条成片的「指纹」：每段用的是原片还是哪个候选
List<int?> _fingerprint(ExportCombination c) =>
    [for (final s in c.segments) s.candidateId];

void main() {
  group('一条都没换', () {
    test('也要产出一条：原片本身就是一种排法', () {
      final combos = _enumerate([
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ]);

      expect(combos, hasLength(1));
      expect(_fingerprint(combos.single), [null, null]);
      expect(combos.single.replacedCount, 0,
          reason: '全是原片的那一条要能被认出来——导出来跟原片一模一样');
    });

    test('段落覆盖全片，不留空档', () {
      final combo = _enumerate([
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ]).single;

      expect(combo.segments.map((s) => (s.startMs, s.endMs)),
          [(0, 2000), (2000, 5000)]);
      expect(combo.durationMs, 5000);
    });
  });

  group('整体替换：一个候选一条变体', () {
    test('两个单元各两个候选 = 四条', () {
      final combos = _enumerate([
        UnitReplacement.whole(const [11, 12]),
        UnitReplacement.whole(const [21, 22]),
      ]);

      expect(combos.map(_fingerprint), [
        [11, 21],
        [11, 22],
        [12, 21],
        [12, 22],
      ], reason: '里程表顺序：最后一个单元变化最快，'
          '前几条之间只有片尾不同，对着导出目录一眼能看出规律');
    });

    test('替换段占的仍是原片那一段的时间位置', () {
      final combo = _enumerate([
        UnitReplacement.whole(const [11]),
        UnitReplacement.keepOriginal(),
      ]).first;

      final replaced = combo.segments.first;
      expect((replaced.startMs, replaced.endMs), (0, 2000),
          reason: '候选比它长就裁、短就补；时长不对齐，后面所有段都错位');
      expect(replaced.unitIndex, 0);
    });

    test('选了模式却没选候选，等同保留原片', () {
      final combos = _enumerate([
        UnitReplacement.whole(const []),
        UnitReplacement.keepOriginal(),
      ]);

      expect(combos, hasLength(1));
      expect(_fingerprint(combos.single), [null, null]);
    });
  });

  group('镜头替换：单元内按镜头拆段', () {
    test('只换其中一个镜头，另一个照旧', () {
      final combos = _enumerate([
        UnitReplacement.perShot(const {
          1: [31],
        }),
        UnitReplacement.keepOriginal(),
      ]);

      final combo = combos.single;
      expect(combo.segments.map((s) => (s.shotIndex, s.candidateId)),
          [(0, null), (1, 31), (null, null)]);
      expect(combo.segments.map((s) => (s.startMs, s.endMs)),
          [(0, 1000), (1000, 2000), (2000, 5000)],
          reason: '镜头层要按镜头边界拆段，否则换的是整句');
    });

    test('两个镜头各两个候选 = 四条（同样是里程表顺序）', () {
      final combos = _enumerate([
        UnitReplacement.perShot(const {
          0: [31, 32],
          1: [41, 42],
        }),
        UnitReplacement.keepOriginal(),
      ]);

      expect(combos.map(_fingerprint), [
        [31, 41, null],
        [31, 42, null],
        [32, 41, null],
        [32, 42, null],
      ]);
    });
  });

  group('两层混着来', () {
    test('单元层与镜头层的因子相乘', () {
      final combos = _enumerate([
        UnitReplacement.perShot(const {
          0: [31, 32],
        }),
        UnitReplacement.whole(const [21, 22]),
      ]);

      expect(combos, hasLength(4));
      expect(_fingerprint(combos.first), [31, null, 21]);
      expect(_fingerprint(combos.last), [32, null, 22]);
    });
  });

  group('上限', () {
    test('超出上限的部分不生成', () {
      final combos = _enumerate([
        UnitReplacement.whole(const [11, 12, 13]),
        UnitReplacement.whole(const [21, 22, 23]),
      ], limit: 4);

      expect(combos, hasLength(4));
      expect(combos.last.index, 4, reason: '编号连续，用于文件名与进度显示');
    });

    test('上限为 0 时一条都不产出，而不是崩', () {
      expect(_enumerate([UnitReplacement.whole(const [11])], limit: 0), isEmpty);
    });

    test('没有单元时返回空', () {
      expect(
          ExportPlanner.enumerate(units: const [], replacements: const []),
          isEmpty);
    });
  });

  group('方案比单元短（切分改过之后的历史数据）', () {
    test('缺的那些单元按保留原片处理，不越界崩掉', () {
      final combos = _enumerate([UnitReplacement.whole(const [11])]);

      expect(combos, hasLength(1));
      expect(_fingerprint(combos.single), [11, null]);
    });
  });

  group('整体替换会改变成片时长', () {
    /// 真机上确认页写「每条约 96.2s」，而底部摘要写「97.2s（原片 96.2s）」
    /// ——用户当场就能看出对不上。整体替换是「原样接上」，时长跟候选走。
    List<SemanticUnit> units() => const [
          SemanticUnit(
              index: 0, startMs: 0, endMs: 4000, transcript: 'U1', shots: []),
          SemanticUnit(
              index: 1, startMs: 4000, endMs: 10000, transcript: 'U2', shots: []),
        ];

    test('候选比原单元长，成片就更长', () {
      final combos = ExportPlanner.enumerate(
        units: units(),
        replacements: [UnitReplacement.whole(const [71])],
        materialDurations: const {71: 5200},
      );

      expect(combos.single.durationMs, 11200,
          reason: '5200（候选）+ 6000（U2 原片），不是 4000 + 6000');
    });

    test('候选比原单元短，成片就更短', () {
      final combos = ExportPlanner.enumerate(
        units: units(),
        replacements: [UnitReplacement.whole(const [71])],
        materialDurations: const {71: 2500},
      );

      expect(combos.single.durationMs, 8500);
    });

    test('探不出候选时长就按原单元算——报得保守好过拿 0 顶', () {
      final combos = ExportPlanner.enumerate(
        units: units(),
        replacements: [UnitReplacement.whole(const [71])],
      );

      expect(combos.single.durationMs, 10000);
    });

    test('每条变体各按自己那个候选算', () {
      final combos = ExportPlanner.enumerate(
        units: units(),
        replacements: [UnitReplacement.whole(const [71, 72])],
        materialDurations: const {71: 5200, 72: 2500},
      );

      expect(combos.map((c) => c.durationMs), [11200, 8500]);
    });

    test('原片区间不受影响——切原片仍按原片毫秒', () {
      final combos = ExportPlanner.enumerate(
        units: units(),
        replacements: [UnitReplacement.whole(const [71])],
        materialDurations: const {71: 5200},
      );
      final segment = combos.single.segments.first;

      expect(segment.startMs, 0);
      expect(segment.endMs, 4000);
      expect(segment.sourceDurationMs, 4000);
      expect(segment.durationMs, 5200);
    });

    test('镜头替换不改时长——那一层是变速对齐原坑位', () {
      const withShots = [
        SemanticUnit(index: 0, startMs: 0, endMs: 4000, transcript: 'U1', shots: [
          Shot(startMs: 0, endMs: 2000),
          Shot(startMs: 2000, endMs: 4000),
        ]),
      ];

      final combos = ExportPlanner.enumerate(
        units: withShots,
        replacements: [
          UnitReplacement.perShot(const {
            0: [71]
          })
        ],
        materialDurations: const {71: 9000},
      );

      expect(combos.single.durationMs, 4000);
    });
  });
}
