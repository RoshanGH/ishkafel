import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
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
  group('剪映工程也要截一段，不是整条压缩', () {
    test('长素材配短坑位：截一段，倍速 1.0', () {
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
      expect(seg.speed, 1.0,
          reason: '14 秒的素材塞进 0.433 秒的坑位，整条压缩就是 32 倍快进');
      expect(seg.durationMs, 433);
      expect(seg.sourceStartMs, greaterThan(0),
          reason: '要从素材中段开始截，开头常有转场');
    });

    test('人调过起点就听人的——和导出那边同一个判断', () {
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

      expect(plan.videoTracks.last.single.sourceStartMs, 9000);
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

}
