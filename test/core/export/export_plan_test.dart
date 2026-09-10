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
  _duplicateMaterialTests();
  _balancedSamplingTests();
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

/// 同一条素材不能在同一条成片里出现两次。
///
/// 笛卡尔积会自然产出这种组合：U1 选了 [A,B]、U2 选了 [A,C]，四条里就有一条
/// 是 A+A。那不是用户想要的——同一个画面在片子里出现两次，一眼就能看出来。
void _duplicateMaterialTests() {
  group('同一条素材不能在一条成片里用两次', () {
    test('含重复素材的组合直接不生成', () {
      final combos = ExportPlanner.enumerate(
        units: _units(),
        replacements: [
          UnitReplacement.whole(const [101, 102]),
          UnitReplacement.whole(const [101, 103]),
        ],
      );

      // 2×2 = 4 种排法，其中 101+101 那条作废
      expect(combos, hasLength(3));
      for (final c in combos) {
        final used = [
          for (final s in c.segments)
            if (s.candidateId != null) s.candidateId!,
        ];
        expect(used.toSet(), hasLength(used.length), reason: '不许有重复');
      }
    });

    test('编号连续——作废的那条不能在编号上留个洞', () {
      final combos = ExportPlanner.enumerate(
        units: _units(),
        replacements: [
          UnitReplacement.whole(const [101, 102]),
          UnitReplacement.whole(const [101, 103]),
        ],
      );
      expect(combos.map((c) => c.index), [1, 2, 3]);
    });

    test('全部组合都因重复作废时返回空——上层据此明说，不静默导 0 条', () {
      final combos = ExportPlanner.enumerate(
        units: _units(),
        replacements: [
          UnitReplacement.whole(const [101]),
          UnitReplacement.whole(const [101]),
        ],
      );
      expect(combos, isEmpty);
    });

    test('不同单元用不同素材时一条都不少', () {
      final combos = ExportPlanner.enumerate(
        units: _units(),
        replacements: [
          UnitReplacement.whole(const [101, 102]),
          UnitReplacement.whole(const [201, 202]),
        ],
      );
      expect(combos, hasLength(4));
    });
  });

  /// 候选选多了是常态，导出只取 100 条——**这 100 条得挑得有意义**。
  ///
  /// 里程表默认从最后一个单元开始进位，前 100 条里前面的单元永远停在
  /// 第一个候选：真机上 U2 选了几百个候选，导出来的 100 条却全是
  /// 「U1 第一个 + U2 第一个 + U3 变来变去」，等于白挑。
  ///
  /// 改成**从候选最多的单元开始变**，同样的 100 条名额落在差异最大的那一维上。
  group('取不完时，这 100 条要挑得有意义', () {
    List<SemanticUnit> unitsOf(int n) => [
          for (var i = 0; i < n; i++)
            SemanticUnit(
                index: i, startMs: i * 1000, endMs: i * 1000 + 1000, transcript: 't$i'),
        ];

    test('候选最多的那个单元变化最快——哪怕它夹在中间', () {
      // 真机形状：候选最多的是 U2，而它后面还有 U3。
      // 从最后一个单元开始进位的话，十条里 U2 一动不动
      final combos = ExportPlanner.enumerate(
        units: unitsOf(3),
        replacements: [
          UnitReplacement.whole([1, 2]),
          UnitReplacement.whole(List.generate(50, (i) => 100 + i)),
          UnitReplacement.whole(List.generate(20, (i) => 200 + i)),
        ],
        limit: 10,
      );

      final u2Ids = {
        for (final c in combos)
          c.segments.firstWhere((s) => s.unitIndex == 1).candidateId,
      };
      expect(u2Ids.length, greaterThan(5),
          reason: '十条里 U2 应该换了好几个候选，而不是十条都用同一个');
    });

    test('还是互不相同——名额有限不能拿重复的凑数', () {
      final combos = ExportPlanner.enumerate(
        units: unitsOf(3),
        replacements: [
          UnitReplacement.whole([1, 2, 3]),
          UnitReplacement.whole([10, 11, 12]),
          UnitReplacement.whole([20, 21, 22]),
        ],
        limit: 20,
      );

      final seen = combos
          .map((c) => c.segments.map((s) => s.candidateId).join(','))
          .toSet();
      expect(seen.length, combos.length);
    });
  });

}

/// 名额不够时怎么取。
///
/// 2026-09-10 用户真机：「一个镜头选了5个替换，但是导出10条全是选用的其中
/// 同一个镜头……任何一个替换的位置都尽量不重复。」根因之一在这儿：原来
/// 超出名额就掐里程表的前 N 条，等于「最低位转个不停，别的位一动不动」，
/// 慢的那一位的候选连进都进不了池子。
void _balancedSamplingTests() {
  SemanticUnit unit(int i, int shots) => SemanticUnit(
        index: i,
        startMs: i * 10000,
        endMs: (i + 1) * 10000,
        transcript: 'U${i + 1}',
        uid: 'u$i',
        shots: [
          for (var s = 0; s < shots; s++)
            Shot(
                startMs: i * 10000 + s * 1000,
                endMs: i * 10000 + (s + 1) * 1000),
        ],
      );

  Map<int?, int> countsAt(List<ExportCombination> list, int shot) {
    final m = <int?, int>{};
    for (final c in list) {
      for (final s in c.segments) {
        if (s.shotIndex == shot) m[s.candidateId] = (m[s.candidateId] ?? 0) + 1;
      }
    }
    return m;
  }

  group('装不下时按位均衡取样', () {
    test('慢的那一位也要摊开——5 个候选不能只出现头两个', () {
      // 5 × 40 = 200 种，名额 100
      final combos = ExportPlanner.enumerate(
        units: [unit(0, 3)],
        replacements: [
          UnitReplacement.perShot({
            0: [101, 102, 103, 104, 105],
            2: [for (var i = 0; i < 40; i++) 200 + i],
          }),
        ],
      );

      expect(combos, hasLength(100));
      final counts = countsAt(combos, 0);
      expect(counts.keys.toSet(), {101, 102, 103, 104, 105},
          reason: '有候选一次都没露面');
      // 100 条摊到 5 条候选上，各 20 次上下
      for (final n in counts.values) {
        expect(n, greaterThanOrEqualTo(15));
        expect(n, lessThanOrEqualTo(25));
      }
    });

    test('单元之间也一样：候选少的那个单元不能被钉死', () {
      final combos = ExportPlanner.enumerate(
        units: [unit(0, 1), unit(1, 1)],
        replacements: [
          UnitReplacement.perShot({0: [for (var i = 0; i < 30; i++) 300 + i]}),
          UnitReplacement.perShot({0: [101, 102, 103, 104, 105]}),
        ],
      );

      final counts = <int?, int>{};
      for (final c in combos) {
        for (final s in c.segments) {
          if (s.unitIndex == 1) counts[s.candidateId] = (counts[s.candidateId] ?? 0) + 1;
        }
      }
      expect(counts.keys.toSet(), {101, 102, 103, 104, 105});
    });

    test('十几个镜头各挑几条也不会先把内存吃掉', () {
      // 5^13 ≈ 12 亿种排法。原来的实现会先把单元内的笛卡尔积整个铺成一个
      // List（[_perShotChoices]），跟名额没关系；现在按需生成，只造那 100 条
      final combos = ExportPlanner.enumerate(
        units: [unit(0, 13)],
        replacements: [
          UnitReplacement.perShot({
            for (var s = 0; s < 13; s++) s: [for (var i = 0; i < 5; i++) s * 100 + i],
          }),
        ],
      );
      expect(combos, hasLength(100));
      // 每一镜的 5 条候选都得露面，一镜都不能被钉死
      for (var s = 0; s < 13; s++) {
        expect(countsAt(combos, s).keys.toSet(), hasLength(5),
            reason: '第 ${s + 1} 镜有候选没露面');
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
