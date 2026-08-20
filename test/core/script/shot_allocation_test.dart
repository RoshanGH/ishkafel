import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/shot_allocation.dart';

/// 行内时长分配：总长锁死、邻镜联动、0.5s 底线、变速改可用量。
LineShot shot(int id, {int? srcMs, int? alloc, double speed = 1.0, int trim = 0}) =>
    LineShot(
        materialId: id,
        name: 's$id',
        durationMs: srcMs,
        allocMs: alloc,
        speed: speed,
        trimStartMs: trim);

void main() {
  group('行时长根', () {
    test('配音行 = 配音时长；没配音分不了', () {
      final line = ScriptLine.create(text: '词');
      expect(ShotAllocation.rootMsOf(line), isNull);
      final withVo = line.withVoiceover(LineVoiceover(
          audioPath: '/a.mp3',
          durationMs: 6000,
          sourceText: '词',
          voiceId: 'v',
          speechRate: 0));
      expect(ShotAllocation.rootMsOf(withVo), 6000);
    });

    test('画面行 = 手填；不填则随素材（变速后的实际时长）', () {
      var line = ScriptLine.create()
          .withShots([shot(1, srcMs: 6000, speed: 1.5), shot(2, srcMs: 3000)]);
      expect(ShotAllocation.rootMsOf(line), 7000, reason: '6s/1.5 + 3s');
      line = line.withManualMs(2500);
      expect(ShotAllocation.rootMsOf(line), 2500, reason: '手填即根');
    });
  });

  group('初始均分（6 秒三镜——设计稿的验收场景）', () {
    test('均分且总和 = 根；从头截、1x', () {
      final shots = ShotAllocation.distribute(
          [shot(1, srcMs: 6000), shot(2, srcMs: 8000), shot(3, srcMs: 7000)],
          6000);
      expect(shots.map((s) => s.allocMs), [2000, 2000, 2000]);
      expect(ShotAllocation.shortfallMs(shots, 6000), 0);
    });

    test('某镜素材不够均分份额时按可用量给，缺口由有余量的镜头补', () {
      final shots = ShotAllocation.distribute(
          [shot(1, srcMs: 1000), shot(2, srcMs: 8000), shot(3, srcMs: 7000)],
          6000);
      expect(shots[0].allocMs, 1000, reason: '只有 1s 素材就出 1s');
      expect(shots[1].allocMs! + shots[2].allocMs!, 5000);
      expect(ShotAllocation.shortfallMs(shots, 6000), 0);
    });

    test('全都不够时留缺口并能算出来——不静默把片子变短', () {
      final shots = ShotAllocation.distribute(
          [shot(1, srcMs: 1000), shot(2, srcMs: 1000)], 6000);
      expect(ShotAllocation.shortfallMs(shots, 6000), 4000);
    });
  });

  group('邻镜联动（总长锁死）', () {
    test('拉长一镜，右邻等量让出', () {
      final shots = ShotAllocation.resize(
          [shot(1, srcMs: 8000, alloc: 2000), shot(2, srcMs: 8000, alloc: 2000), shot(3, srcMs: 8000, alloc: 2000)],
          0,
          3000)!;
      expect(shots.map((s) => s.allocMs), [3000, 1000, 3000 - 1000]);
    });

    test('右邻到 0.5s 底线吃不下时换左邻', () {
      final shots = ShotAllocation.resize(
          [shot(1, srcMs: 8000, alloc: 2000), shot(2, srcMs: 8000, alloc: 2000), shot(3, srcMs: 8000, alloc: 600)],
          1,
          3000)!;
      expect(shots[2].allocMs, 600, reason: '右邻只有 100ms 余量，吃不下整个差额');
      expect(shots[0].allocMs, 1000, reason: '换左邻吸收');
      expect(shots[1].allocMs, 3000);
    });

    test('邻居都到底了 → 返回 null（界面解释原因）', () {
      expect(
          ShotAllocation.resize(
              [shot(1, srcMs: 8000, alloc: 500), shot(2, srcMs: 8000, alloc: 500)],
              0,
              2000),
          isNull);
    });

    test('目标夹在最小值与可用量之间', () {
      final shots = ShotAllocation.resize(
          [shot(1, srcMs: 2000, alloc: 1000), shot(2, srcMs: 8000, alloc: 5000)],
          0,
          99999)!;
      expect(shots[0].allocMs, 2000, reason: '素材只有 2s，1x 下最多出 2s');
    });
  });

  group('框选与变速', () {
    test('起点右移不能把剩余素材挤到不够出本镜', () {
      final s = ShotAllocation.setTrimStart(
          shot(1, srcMs: 6000, alloc: 2000), 5500);
      expect(s.trimStartMs, 4000, reason: '起点最多到 6000-2000');
    });

    test('变速清框重选：起点归零、可用量按新速率算', () {
      final s = ShotAllocation.setSpeed(
          shot(1, srcMs: 6000, alloc: 2000, trim: 3000), 1.5);
      expect(s.trimStartMs, 0);
      expect(s.availableMs, 4000, reason: '6s 素材 1.5x 只够出 4s');
      expect(s.allocMs, 2000, reason: '分配没超可用量就不动');
    });

    test('变速后可用量不够当前分配时压到可用量', () {
      final s = ShotAllocation.setSpeed(shot(1, srcMs: 3000, alloc: 2500), 1.5);
      expect(s.allocMs, 2000, reason: '3s 素材 1.5x 只够 2s');
    });
  });

  group('放慢充满（素材偏短时自动降速吃掉缺口）', () {
    test('单镜素材短于根：放慢到刚好充满，缺口清零', () {
      final distributed =
          ShotAllocation.distribute([shot(1, srcMs: 4000)], 6000);
      expect(ShotAllocation.shortfallMs(distributed, 6000), 2000);
      final filled = ShotAllocation.fillBySlowdown(distributed, 6000);
      expect(ShotAllocation.shortfallMs(filled, 6000), 0,
          reason: '放慢后镜头充满整行');
      expect(filled.single.speed, lessThan(1.0));
      expect(filled.single.availableMs,
          greaterThanOrEqualTo(filled.single.allocMs!));
    });

    test('多镜合计不够：从后往前放慢，先动最后一镜', () {
      final distributed = ShotAllocation.distribute(
          [shot(1, srcMs: 4000), shot(2, srcMs: 3000)], 9000);
      expect(ShotAllocation.shortfallMs(distributed, 9000), 2000);
      final filled = ShotAllocation.fillBySlowdown(distributed, 9000);
      expect(ShotAllocation.shortfallMs(filled, 9000), 0);
      expect(filled[0].speed, 1.0, reason: '最后一镜能吃下缺口就不动前面的');
      expect(filled[1].speed, lessThan(1.0));
    });

    test('放慢有底线：0.5x 还不够就留缺口继续警告，不做鬼畜慢放', () {
      final distributed =
          ShotAllocation.distribute([shot(1, srcMs: 1000)], 6000);
      final filled = ShotAllocation.fillBySlowdown(distributed, 6000);
      expect(filled.single.speed, 0.5);
      expect(ShotAllocation.shortfallMs(filled, 6000), 4000,
          reason: '1s 素材 0.5x 只够 2s，剩 4s 缺口如实报');
    });

    test('本来就满的行原样返回，已手动加速的镜头只降不升', () {
      final full = ShotAllocation.distribute([shot(1, srcMs: 8000)], 6000);
      expect(ShotAllocation.fillBySlowdown(full, 6000), same(full));
      // 手动 1.5x 的镜头缺口时往回降速也算「放慢」
      final fast = [shot(1, srcMs: 6000, alloc: 4000, speed: 1.5)];
      final filled = ShotAllocation.fillBySlowdown(fast, 6000);
      expect(ShotAllocation.shortfallMs(filled, 6000), 0);
      expect(filled.single.speed, lessThan(1.5));
    });
  });
}
