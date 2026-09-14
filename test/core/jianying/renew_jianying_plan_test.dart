import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/jianying/jianying_plan.dart';
import 'package:ishkafel/core/jianying/renew_jianying_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 替换裂变导剪映：**一个任务一份工程**，所有候选都摆进去。
///
/// 用户定的形状：即便一个替换都不选，也该有字幕、配乐、分子、原子这几条轨；
/// 某个分子挑了 4 条候选，它下面就多出 4 条轨；原子同理。最宽的地方有几条轨，
/// 整份工程就有几条——上层盖下层，人在剪映里把上面那条关掉，下面那条就露出来。
void main() {
  SemanticUnit unit(int i, int start, int end, {List<Shot> shots = const []}) =>
      SemanticUnit(
          index: i,
          startMs: start,
          endMs: end,
          transcript: 'U$i',
          shots: shots);

  Shot shot(int start, int end) => Shot(startMs: start, endMs: end);

  const source = '/tmp/原片.mp4';
  String? material(int id) => '/tmp/素材$id.mp4';

  test('一个替换都不选：分子轨、原子轨都铺满原片', () {
    final plan = buildRenewJianyingPlan(
      units: [unit(0, 0, 3000, shots: [shot(0, 1000), shot(1000, 3000)])],
      replacements: const [],
      sourcePath: source,
      sourceTotalMs: 3000,
      materialOf: material,
      materialDurationOf: (_) => 5000,
    );

    expect(plan.videoTracks, hasLength(2), reason: '分子一条、原子一条');
    expect(plan.videoTracks[0].single.path, source);
    expect(plan.videoTracks[0].single.durationMs, 3000);
    expect(plan.videoTracks[1], hasLength(2), reason: '原子轨按视觉镜头切开');
  });

  test('分子挑了三条候选，就在它上面多出三条轨', () {
    final plan = buildRenewJianyingPlan(
      units: [unit(0, 0, 3000), unit(1, 3000, 5000)],
      replacements: [
        UnitReplacement.whole([11, 12, 13]),
        UnitReplacement.keepOriginal(),
      ],
      sourcePath: source,
      sourceTotalMs: 5000,
      materialOf: material,
      materialDurationOf: (_) => 4000,
    );

    // 分子轨 + 原子轨 + 三条候选轨
    expect(plan.videoTracks, hasLength(5));
    expect(plan.videoTracks[2].single.path, '/tmp/素材11.mp4');
    expect(plan.videoTracks[3].single.path, '/tmp/素材12.mp4');
    expect(plan.videoTracks[4].single.path, '/tmp/素材13.mp4');
  });

  test('候选摆在它替换的那个位置上，长度也是那个坑位的长度', () {
    final plan = buildRenewJianyingPlan(
      units: [unit(0, 0, 3000), unit(1, 3000, 5000)],
      replacements: [
        UnitReplacement.keepOriginal(),
        UnitReplacement.whole([11]),
      ],
      sourcePath: source,
      sourceTotalMs: 5000,
      materialOf: material,
      materialDurationOf: (_) => 8000,
    );

    final seg = plan.videoTracks.last.single;
    expect(seg.atMs, 3000, reason: 'U2 的坑位从 3 秒开始');
    expect(seg.durationMs, 2000, reason: '坑位两秒，素材再长也只占两秒');
    // 以前这里断言的是「八秒塞进两秒 = 四倍速」——那正是要消灭的行为。
    // 现在从素材里截两秒用，倍速回到 1.0
    expect(seg.speed, 1.0);
    expect(seg.sourceStartMs, greaterThan(0), reason: '从素材中段截');
  });

  test('原子替换排在原子轨上面，按最宽的那个位置决定轨数', () {
    final plan = buildRenewJianyingPlan(
      units: [
        unit(0, 0, 3000, shots: [shot(0, 1000), shot(1000, 3000)])
      ],
      replacements: [
        UnitReplacement.perShot({
          0: [21, 22],
          1: [31, 32, 33],
        }),
      ],
      sourcePath: source,
      sourceTotalMs: 3000,
      materialOf: material,
      materialDurationOf: (_) => 4000,
    );

    // 分子轨 + 原子轨 + 三条候选轨（最宽的那个镜头挑了 3 条）
    expect(plan.videoTracks, hasLength(5));
    // 第一条候选轨上，两个镜头各摆各的第一候选
    expect(plan.videoTracks[2].map((s) => s.path),
        ['/tmp/素材21.mp4', '/tmp/素材31.mp4']);
    // 第三条候选轨只有第二个镜头有第三候选
    expect(plan.videoTracks[4].single.path, '/tmp/素材33.mp4');
  });

  test('素材没落到本地就直接抛——工程里少一段，人要到剪映里才发现', () {
    expect(
        () => buildRenewJianyingPlan(
              units: [unit(0, 0, 3000)],
              replacements: [
                UnitReplacement.whole([11])
              ],
              sourcePath: source,
              sourceTotalMs: 3000,
              materialOf: (_) => null,
              materialDurationOf: (_) => 4000,
            ),
        throwsA(isA<Exception>()));
  });

  test('字幕轨：台词按 ASR 句子摆上去，人在剪映里能直接改字', () {
    final plan = buildRenewJianyingPlan(
      units: [unit(0, 0, 3000)],
      replacements: const [],
      sourcePath: source,
      sourceTotalMs: 3000,
      materialOf: material,
      materialDurationOf: (_) => 4000,
      sentences: const [
        AsrSentence(startMs: 0, endMs: 1500, text: '早就跟你们说了'),
        AsrSentence(startMs: 1500, endMs: 3000, text: '衣服混洗有细菌'),
      ],
    );

    expect(plan.text.map((t) => t.text), ['早就跟你们说了', '衣服混洗有细菌']);
    expect(plan.text.first.atMs, 0);
    expect(plan.text.last.durationMs, 1500);
  });

  test('配乐轨：每段铺它选的第一首，从这一段的第一个分子开始', () {
    final plan = buildRenewJianyingPlan(
      units: [unit(0, 0, 3000), unit(1, 3000, 5000)],
      replacements: const [],
      sourcePath: source,
      sourceTotalMs: 5000,
      materialOf: material,
      materialDurationOf: (_) => 4000,
      bgm: const BgmPlan([
        BgmSegment(startUnit: 1, endUnit: 1, fit: BgmFit.cut, materials: [
          BgmMaterial(
              id: 7, name: '轻快', durationMs: 30000, previewUrl: null),
        ]),
      ]),
      bgmPathOf: (id) => '/tmp/bgm$id.mp3',
    );

    expect(plan.bgm, hasLength(1));
    expect(plan.bgm.single.path, '/tmp/bgm7.mp3');
    expect(plan.bgm.single.atMs, 3000);
    expect(plan.bgm.single.durationMs, 2000);
  });


  /// 剪映工程必须和导出 mp4 **同一个口径**：导出那边已经改成「从素材里
  /// 截一段」了，剪映这边还在整条压缩——同一条片子导 mp4 是 1.0 倍速，
  /// 拖进剪映却是三十几倍快进，人会以为软件坏了。
  group('剪映工程和导出、预览走同一个算法', () {
    test('视觉镜头替换：整条素材变速铺满坑位，不截', () {
      final plan = buildRenewJianyingPlan(
        units: [
          unit(0, 0, 3000, shots: [shot(0, 433), shot(433, 3000)])
        ],
        replacements: [
          UnitReplacement.perShot({
            0: [21]
          }),
        ],
        sourcePath: source,
        sourceTotalMs: 3000,
        materialOf: material,
        materialDurationOf: (_) => 14000,
      );

      final seg = plan.videoTracks.last.single;
      expect(seg.speed, closeTo(14000 / 433, 1e-6),
          reason: '14 秒的素材铺满 0.433 秒的坑位就是 32 倍快进——'
              '导出 mp4 也是这个数，两边不许分叉');
      expect(seg.durationMs, 433, reason: '在成片轴上仍然只占原镜头那么长');
      expect(seg.sourceStartMs, 0, reason: '不截，从头用');
      expect(seg.sourceDurationMs, 14000, reason: '整条素材都进去了');
    });

    test('人调过起点：跳过开头那截，剩下的照旧铺满', () {
      final plan = buildRenewJianyingPlan(
        units: [
          unit(0, 0, 3000, shots: [shot(0, 500), shot(500, 3000)])
        ],
        replacements: [
          UnitReplacement.perShot({
            0: [21]
          }, trimStarts: {
            0: {21: 9000}
          }),
        ],
        sourcePath: source,
        sourceTotalMs: 3000,
        materialOf: material,
        materialDurationOf: (_) => 20000,
      );

      final seg = plan.videoTracks.last.single;
      expect(seg.sourceStartMs, 9000);
      expect(seg.sourceDurationMs, 11000, reason: '从 9 秒到结尾全都要');
      expect(seg.speed, closeTo(11000 / 500, 1e-6));
    });

    /// 「铺满原镜头时长」是**视觉镜头替换**那一层的规则。整体替换换的是
    /// 整段画面加声音、时长本来就跟着候选走，不归它管——这里留一条线，
    /// 免得下次改镜头层时顺手把这一层也拖下水
    test('整体替换不走铺满：仍然截一段、倍速 1.0', () {
      final plan = buildRenewJianyingPlan(
        units: [unit(0, 0, 3000, shots: [shot(0, 3000)])],
        replacements: [UnitReplacement.whole([21])],
        sourcePath: source,
        sourceTotalMs: 3000,
        materialOf: material,
        materialDurationOf: (_) => 20000,
      );

      final seg = plan.videoTracks.last.single;
      expect(seg.speed, 1.0);
      expect(seg.sourceDurationMs, 3000);
    });

    test('素材本身不够长：照旧放慢，如实给出倍速', () {
      final plan = buildRenewJianyingPlan(
        units: [
          unit(0, 0, 3000, shots: [shot(0, 2000), shot(2000, 3000)])
        ],
        replacements: [
          UnitReplacement.perShot({
            0: [21]
          }),
        ],
        sourcePath: source,
        sourceTotalMs: 3000,
        materialOf: material,
        materialDurationOf: (_) => 800,
      );

      final seg = plan.videoTracks.last.single;
      expect(seg.speed, closeTo(0.4, 0.01));
      expect(seg.sourceStartMs, 0);
    });
  });


  group('固定过底片的单元：工程里那几段要指到素材，不是原片', () {
    // U0 取自原片 0~10000；U1 取自原片 10000~14000，底片换成 6 秒的素材 7
    final pinnedUnits = [
      unit(0, 0, 10000, shots: [shot(0, 10000)]),
      SemanticUnit(
        index: 1,
        startMs: 10000,
        endMs: 14000,
        transcript: 'U1',
        baseCandidateId: 7,
        shots: [shot(10000, 12000), shot(12000, 16000)],
      ),
    ];

    List<JyVideoSegment> atomOf(JianyingPlan plan) => plan.videoTracks[1];

    JianyingPlan build({String? Function(int)? materialOf}) =>
        buildRenewJianyingPlan(
          units: pinnedUnits,
          replacements: [
            UnitReplacement.keepOriginal(),
            UnitReplacement.whole([7], previewId: 7),
          ],
          sourcePath: source,
          sourceTotalMs: 14000,
          materialOf: materialOf ?? material,
          materialDurationOf: (id) => 6000,
        );

    test('原子轨上这两镜用的是素材文件', () {
      final pinned =
          atomOf(build()).where((s) => s.path == '/tmp/素材7.mp4').toList();

      expect(pinned.length, 2);
    });

    test('取的是素材内偏移——不减掉单元起点就是原片里另一个时间点', () {
      final pinned =
          atomOf(build()).where((s) => s.path == '/tmp/素材7.mp4').toList();

      expect(pinned[0].sourceStartMs, 0);
      expect(pinned[1].sourceStartMs, 2000);
    });

    test('素材有多长由它自己说了算，不拿原片总长去夹', () {
      final pinned =
          atomOf(build()).where((s) => s.path == '/tmp/素材7.mp4').toList();

      expect(pinned.first.sourceTotalMs, 6000);
    });

    test('取自原片的那一段不受影响', () {
      final fromSource =
          atomOf(build()).where((s) => s.path == source).toList();

      expect(fromSource.length, 1);
      expect(fromSource.single.sourceStartMs, 0);
    });

    test('候选轨不再摆同一条素材——原子轨上已经有了，摆两遍是重复画面', () {
      final plan = build();
      // 分子轨、原子轨之上才是候选轨
      final candidates = plan.videoTracks.skip(2).expand((t) => t);

      expect(candidates.where((s) => s.path == '/tmp/素材7.mp4'), isEmpty);
    });

    test('底片素材没落地：点名，不静默摆一段原片顶上', () {
      expect(() => build(materialOf: (id) => null),
          throwsA(isA<JianyingPlanException>()));
    });
  });
}
