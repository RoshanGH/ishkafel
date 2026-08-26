import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/jianying/jianying_plan.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/sound_mix.dart';

/// 剪映草稿计划：**剪映里看到的就是 ishkafel 里的结果**。
/// 用户在这边调的每一个数，进剪映后必须还是那个数——不多算、不代偿。

LineShot shot({
  int id = 100,
  int? durationMs = 10000,
  int trimStartMs = 0,
  double speed = 1.0,
  int? allocMs = 2000,
  double? sourceVolume,
  String? localSource,
}) =>
    LineShot(
      materialId: id,
      name: '素材$id',
      durationMs: durationMs,
      trimStartMs: trimStartMs,
      speed: speed,
      allocMs: allocMs,
      sourceVolume: sourceVolume,
      localSource: localSource,
    );

ScriptDoc docOf(List<ScriptLine> lines, {SoundMix mix = const SoundMix()}) =>
    ScriptDoc(lines, mix: mix);

ScriptLine visual(List<LineShot> shots) =>
    ScriptLine.create().withShots(shots);

/// 素材路径解析：测试里直接按 id 编一个
String? srcOf(LineShot s) => s.localSource ?? '/m/${s.materialId}.mp4';

void main() {
  group('变速：用户设的倍率原样进剪映，不自己算', () {
    test('speed 原样带过去', () {
      final plan = buildJianyingPlan(
        docOf([
          visual([shot(speed: 0.26, allocMs: 4000, durationMs: 10000)])
        ]),
        sourceOf: srcOf,
      );
      expect(plan.video.single.speed, 0.26);
    });

    test('吃掉的素材量 = allocMs × speed，占位仍是 allocMs', () {
      final plan = buildJianyingPlan(
        docOf([
          visual([shot(speed: 2.0, allocMs: 3000, durationMs: 10000)])
        ]),
        sourceOf: srcOf,
      );
      final seg = plan.video.single;
      expect(seg.durationMs, 3000, reason: '在成片上占 3 秒');
      expect(seg.sourceDurationMs, 6000, reason: '2 倍速要吃掉 6 秒素材');
    });

    test('框选起点原样带过去', () {
      final plan = buildJianyingPlan(
        docOf([
          visual([shot(trimStartMs: 19953, allocMs: 2424, durationMs: 30000)])
        ]),
        sourceOf: srcOf,
      );
      expect(plan.video.single.sourceStartMs, 19953);
    });
  });

  group('音量：调 0 就是静音，调一半就是一半', () {
    test('这一镜显式设 0 → 剪映里就是 0', () {
      final plan = buildJianyingPlan(
        docOf([
          visual([shot(sourceVolume: 0.0)])
        ]),
        sourceOf: srcOf,
      );
      expect(plan.video.single.volume, 0.0);
    });

    test('这一镜设 0.5 → 剪映里就是 0.5', () {
      final plan = buildJianyingPlan(
        docOf([
          visual([shot(sourceVolume: 0.5)])
        ]),
        sourceOf: srcOf,
      );
      expect(plan.video.single.volume, 0.5);
    });

    test('走的是 sourceVolumeFor —— 全片总控要乘进去', () {
      const mix = SoundMix(source: 0.4);
      final doc = docOf([
        visual([shot(sourceVolume: 0.5)])
      ], mix: mix);
      final plan = buildJianyingPlan(doc, sourceOf: srcOf);
      expect(plan.video.single.volume, doc.sourceVolumeFor(doc.lines.first, doc.lines.first.shots.first),
          reason: '音量只能有一个权威来源，不许在这里另算一套');
    });
  });

  group('时间线：镜头首尾相接，行与行相接', () {
    test('同一行的镜头顺序排开', () {
      final plan = buildJianyingPlan(
        docOf([
          visual([shot(allocMs: 1000), shot(allocMs: 1500), shot(allocMs: 500)])
        ]),
        sourceOf: srcOf,
      );
      expect(plan.video.map((s) => (s.atMs, s.durationMs)).toList(),
          [(0, 1000), (1000, 1500), (2500, 500)]);
      expect(plan.totalMs, 3000);
    });

    test('多行首尾相接', () {
      final plan = buildJianyingPlan(
        docOf([
          visual([shot(allocMs: 1000)]),
          visual([shot(allocMs: 2000)]),
        ]),
        sourceOf: srcOf,
      );
      expect(plan.video.map((s) => s.atMs).toList(), [0, 1000]);
      expect(plan.totalMs, 3000);
    });
  });

  group('不静默降级：数据不对就点名，绝不自己代偿', () {
    test('素材铺不满坑位 → 报错并点名是哪一行哪一镜', () {
      // 素材 2 秒、原速，却被分了 3 秒
      expect(
        () => buildJianyingPlan(
          docOf([
            visual([shot(id: 777, durationMs: 2000, allocMs: 3000)])
          ]),
          sourceOf: srcOf,
        ),
        throwsA(isA<JianyingPlanException>()
            .having((e) => e.message, 'message', contains('第 1 行'))
            .having((e) => e.message, 'message', contains('第 1 镜'))),
        reason: '铺不满绝不能自己算个倍率填上——那是把数据问题偷偷变成画面被拉慢',
      );
    });

    test('素材还没就绪 → 报错并点名', () {
      expect(
        () => buildJianyingPlan(
          docOf([
            visual([shot(id: 888)])
          ]),
          sourceOf: (s) => null, // 还没下载完
        ),
        throwsA(isA<JianyingPlanException>()
            .having((e) => e.message, 'message', contains('素材'))),
      );
    });

    test('镜头还没分时长 → 报错', () {
      expect(
        () => buildJianyingPlan(
          docOf([
            visual([shot(allocMs: null)])
          ]),
          sourceOf: srcOf,
        ),
        throwsA(isA<JianyingPlanException>()),
      );
    });
  });
}
