import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/replacement/candidate_trim.dart';

/// 替换裂变一直是「**整条素材压缩进坑位**」：不管素材多长，拉伸到坑位长度。
///
/// 原片的快切镜头是 0.4~1 秒，而素材库里的分镜普遍 4~30 秒——真机上一条
/// 34 镜的片子里，坑位不到 1.5 秒的有 13 个，将近四成。验收 Agent 探完
/// 全页 50 条候选，最短那一镜（433ms）**倍速最接近 1 的是 9.44**：
/// 库里根本没有那么短的素材。
///
/// 这跟挑得好不好无关，是模型本身的问题。人拿剪辑软件做这件事的方式是
/// **从长素材里截一段**，不是把 20 秒拉成 0.5 秒。
void main() {
  group('从素材里截一段，而不是整条压缩', () {
    test('素材比坑位长：截中段，倍速就是 1.0', () {
      final cut = trimFor(materialMs: 20000, slotMs: 500);

      expect(cut.durationMs, 500);
      expect(cut.speed, 1.0);
      // 开头常有转场和黑帧，中段画面最稳
      expect(cut.startMs, (20000 - 500) ~/ 2);
    });

    test('素材比坑位短：截不出来，只能放慢——如实给出倍速', () {
      final cut = trimFor(materialMs: 800, slotMs: 17335);

      expect(cut.startMs, 0);
      expect(cut.durationMs, 800);
      expect(cut.speed, closeTo(800 / 17335, 0.0001),
          reason: '0.8 秒的画面撑满 17.3 秒就是 0.05 倍速，'
              '该拦的是提交那一步，不是在这儿假装没事');
    });

    test('刚好一样长：不截也不变速', () {
      final cut = trimFor(materialMs: 3000, slotMs: 3000);

      expect(cut.startMs, 0);
      expect(cut.speed, 1.0);
    });

    test('人指定了起点就听人的，别自作主张挪到中间', () {
      final cut = trimFor(materialMs: 20000, slotMs: 500, startMs: 12000);

      expect(cut.startMs, 12000);
      expect(cut.durationMs, 500);
      expect(cut.speed, 1.0);
    });

    test('指定的起点太靠后、后面不够一个坑位：贴着尾巴截，不越界', () {
      final cut = trimFor(materialMs: 20000, slotMs: 500, startMs: 19900);

      expect(cut.startMs, 19500);
      expect(cut.durationMs, 500);
      expect(cut.speed, 1.0);
    });

    test('量不到素材时长时不硬猜：退回整条压缩的老路', () {
      final cut = trimFor(materialMs: 0, slotMs: 500);

      expect(cut.startMs, 0);
      expect(cut.durationMs, 500);
      expect(cut.speed, 1.0);
    });
  });

  group('这条素材配这个坑位合不合适', () {
    test('截得出等长的一段就是合适的', () {
      expect(trimFor(materialMs: 20000, slotMs: 500).isNatural, isTrue);
    });

    test('素材太短、只能拉慢的不合适', () {
      expect(trimFor(materialMs: 800, slotMs: 17335).isNatural, isFalse);
    });

    test('略短一点仍算合适——1.25 倍以内人眼看不出来', () {
      expect(trimFor(materialMs: 2400, slotMs: 3000).isNatural, isTrue);
      expect(trimFor(materialMs: 1000, slotMs: 3000).isNatural, isFalse);
    });
  });

  /// 真机数据：102 条候选里 74 条素材比坑位长 3 倍以上，最夸张的 24 倍
  /// （19 秒素材配 0.8 秒坑位）。「截哪一段」的选择空间非常大，
  /// 自动取中段只是一个赌注——人必须能自己挪，界面要知道能挪到哪儿。
  group('能挪到哪儿', () {
    test('素材比坑位长：起点能从 0 挪到「再往后就不够一个坑位」为止', () {
      final r = trimRange(materialMs: 20000, slotMs: 500);

      expect(r.canAdjust, isTrue);
      expect(r.minStartMs, 0);
      expect(r.maxStartMs, 19500);
    });

    test('素材不够长：没得挪，说清原因', () {
      final r = trimRange(materialMs: 800, slotMs: 17335);

      expect(r.canAdjust, isFalse);
      expect(r.minStartMs, 0);
      expect(r.maxStartMs, 0);
    });

    test('刚好等长也没得挪', () {
      expect(trimRange(materialMs: 3000, slotMs: 3000).canAdjust, isFalse);
    });

    test('量不出素材时长时不假装能挪', () {
      expect(trimRange(materialMs: 0, slotMs: 500).canAdjust, isFalse);
    });
  });

}
