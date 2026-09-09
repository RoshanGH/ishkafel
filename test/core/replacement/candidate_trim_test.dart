import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/replacement/candidate_trim.dart';

/// 视觉镜头替换怎么把候选放进坑位，来回改过两版：
///
/// 一版是「**整条素材压缩进坑位**」。原片的快切镜头是 0.4~1 秒，而素材库
/// 里的分镜普遍 4~30 秒——真机上一条 34 镜的片子里，坑位不到 1.5 秒的有
/// 13 个，将近四成；最短那一镜（433ms）整页 50 条候选里倍速最接近 1 的是
/// 9.44。于是改成了第二版：**从长素材里截一段**，倍速回到 1.0。
///
/// 截段的代价是画面被剪掉大半，真机上看到的就是「本该变速的镜头被剪切
/// 了」。2026-09-09 产品负责人定回第一版：「替换裂变这个模块下的视觉镜头
/// 替换，全部走自动变速充满原镜头时长的方案。」倍速的代价改为**如实报给
/// 挑素材的人**（候选卡上的倍速徽标、`speedIfPicked`），而不是替他剪掉。
///
/// 剪映工程里的**整体替换**不归这条规则管（`fillBySpeed: false`）：
/// 那一层的时长本来就跟着候选走。
void main() {
  group('整条变速铺满坑位，不自动截断', () {
    test('素材比坑位长：整条都用，倍速就是长出来的那个倍数', () {
      final cut = trimFor(materialMs: 20000, slotMs: 500);

      expect(cut.startMs, 0, reason: '从头用，一帧都不丢');
      expect(cut.durationMs, 20000);
      expect(cut.speed, 40.0,
          reason: '20 秒压进 0.5 秒就是 40 倍——这个代价要如实报出去，'
              '而不是替人把画面剪掉');
    });

    test('素材比坑位短：整条用，放慢撑满——如实给出倍速', () {
      final cut = trimFor(materialMs: 800, slotMs: 17335);

      expect(cut.startMs, 0);
      expect(cut.durationMs, 800);
      expect(cut.speed, closeTo(800 / 17335, 0.0001),
          reason: '0.8 秒的画面撑满 17.3 秒就是 0.05 倍速，'
              '该拦的是提交那一步，不是在这儿假装没事');
    });

    test('刚好一样长：不变速', () {
      final cut = trimFor(materialMs: 3000, slotMs: 3000);

      expect(cut.startMs, 0);
      expect(cut.durationMs, 3000);
      expect(cut.speed, 1.0);
    });

    test('人指定了起点：跳过开头那一截，剩下的照旧整条铺满', () {
      final cut = trimFor(materialMs: 20000, slotMs: 500, startMs: 12000);

      expect(cut.startMs, 12000);
      expect(cut.durationMs, 8000, reason: '从 12 秒到结尾全都要，不是只取 500ms');
      expect(cut.speed, 16.0);
    });

    test('起点挪到最靠后：剩下的正好一个坑位，倍速回到 1.0', () {
      final cut = trimFor(materialMs: 20000, slotMs: 500, startMs: 19900);

      expect(cut.startMs, 19500, reason: '再往后剩的就不够铺满坑位了');
      expect(cut.durationMs, 500);
      expect(cut.speed, 1.0);
    });

    test('量不到素材时长时不硬猜：给坑位长、倍速 1.0，交给导出那头现算', () {
      final cut = trimFor(materialMs: 0, slotMs: 500);

      expect(cut.startMs, 0);
      expect(cut.durationMs, 500);
      expect(cut.speed, 1.0);
    });
  });

  /// 剪映工程里的整体替换还走老的截段规则——那一层不归「铺满原镜头时长」
  /// 管，改它是另一件事
  group('fillBySpeed: false 时仍然截一段', () {
    test('素材比坑位长：截中段，倍速 1.0', () {
      final cut =
          trimFor(materialMs: 20000, slotMs: 500, fillBySpeed: false);

      expect(cut.startMs, (20000 - 500) ~/ 2);
      expect(cut.durationMs, 500);
      expect(cut.speed, 1.0);
    });

    test('素材比坑位短：整条用，放慢撑满', () {
      final cut =
          trimFor(materialMs: 800, slotMs: 17335, fillBySpeed: false);

      expect(cut.durationMs, 800);
      expect(cut.speed, closeTo(800 / 17335, 0.0001));
    });
  });

  group('这条素材配这个坑位合不合适', () {
    test('长素材配短坑位不合适——整条铺满就是几十倍快放', () {
      expect(trimFor(materialMs: 20000, slotMs: 500).isNatural, isFalse);
    });

    test('长度对得上的才合适', () {
      expect(trimFor(materialMs: 3200, slotMs: 3000).isNatural, isTrue);
      expect(trimFor(materialMs: 6000, slotMs: 3000).isNatural, isFalse);
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
  /// （19 秒素材配 0.8 秒坑位）。默认整条铺满就是 24 倍快放；素材开头是
  /// 转场或黑帧时人要能把起点往后挪，界面得知道能挪到哪儿。
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
