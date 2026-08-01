import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/frame_signal.dart';
import 'package:ishkafel/core/analysis/shot_boundary_detector.dart';

/// 真实素材 JC_滴露_植源喷雾_XCT 上人工逐个核对过的样本
/// （抽出切点前后两帧目视确认，过程见 docs/plans/2026-08-01-镜头切分优化.md）
const _labelled = <({int ms, double scene, double hist, bool isCut, String note})>[
  (ms: 7467, scene: 0.339, hist: 0.570, isCut: true, note: '手持喷瓶特写 → 台面三瓶'),
  (ms: 30267, scene: 0.339, hist: 0.490, isCut: true, note: '气球摆台 → 厨房全景'),
  (ms: 18300, scene: 0.299, hist: 0.374, isCut: false, note: '冰箱前手快速移动'),
  (ms: 79033, scene: 0.128, hist: 0.281, isCut: false, note: '擦电饭煲，手拿起蓝布'),
  (ms: 47767, scene: 0.059, hist: 0.242, isCut: false, note: '冰箱内，几乎无变化'),
  (ms: 26167, scene: 0.129, hist: 0.149, isCut: false, note: '擦微波炉，手位置略变'),
  (ms: 93500, scene: 0.129, hist: 0.090, isCut: false, note: '窗边洗碗，手在动'),
  (ms: 53267, scene: 0.065, hist: 0.055, isCut: false, note: '冰箱内，几乎无变化'),
  (ms: 20433, scene: 0.064, hist: 0.042, isCut: false, note: '喷电饭煲，几乎无变化'),
];

FrameSignal _sig(int ms, double scene, double hist) =>
    FrameSignal(ms: ms, sceneScore: scene, histDistance: hist);

const _detector = ShotBoundaryDetector();

void main() {
  group('真实标注样本（人工抽帧核对过）', () {
    test('两个真实切换都被确认，不需要复核', () {
      for (final s in _labelled.where((s) => s.isCut)) {
        final got = _detector.detect([_sig(s.ms, s.scene, s.hist)]);

        expect(got, hasLength(1), reason: '${s.note} 被整个漏掉了');
        expect(got.single.isConfirmed, isTrue,
            reason: '${s.note}：直方图 ${s.hist} 已经明显高于所有误检样本，'
                '还要送去复核是浪费');
      }
    });

    test('误检样本一律不被直接确认', () {
      for (final s in _labelled.where((s) => !s.isCut)) {
        final got = _detector.detect([_sig(s.ms, s.scene, s.hist)]);

        expect(got.where((c) => c.isConfirmed), isEmpty,
            reason: '${s.note}：画面内容没换，只是动得厉害。'
                '直接确认成切点，用户就得手动合并');
      }
    });

    test('判别力最强的那条界线落在直方图上，不在 scene 分数上', () {
      final cutHist = [for (final s in _labelled.where((s) => s.isCut)) s.hist];
      final notHist = [for (final s in _labelled.where((s) => !s.isCut)) s.hist];
      final cutScene = [for (final s in _labelled.where((s) => s.isCut)) s.scene];
      final notScene = [
        for (final s in _labelled.where((s) => !s.isCut)) s.scene
      ];

      final histGap = cutHist.reduce((a, b) => a < b ? a : b) -
          notHist.reduce((a, b) => a > b ? a : b);
      final sceneGap = cutScene.reduce((a, b) => a < b ? a : b) -
          notScene.reduce((a, b) => a > b ? a : b);

      expect(histGap, greaterThan(sceneGap * 2),
          reason: '这条测试记录的是选型依据：直方图上真假之间空档 '
              '${histGap.toStringAsFixed(3)}，scene 分数上只有 '
              '${sceneGap.toStringAsFixed(3)}。所以高线以直方图为主');
    });

    test('最像切换的那个误检落在灰区，会被送去复核而不是直接丢掉', () {
      final s = _labelled.firstWhere((s) => s.ms == 18300);

      final got = _detector.detect([_sig(s.ms, s.scene, s.hist)]);

      expect(got, hasLength(1));
      expect(got.single.confidence, BoundaryConfidence.uncertain,
          reason: '0.374 已经很接近真实切换了，靠数值一刀切必然出错，'
              '这正是需要看一眼画面的情形');
    });
  });

  group('过密切点合并', () {
    test('一次切换在相邻几帧都触发时只保留最强的那一帧', () {
      final got = _detector.detect([
        _sig(1000, 0.30, 0.45),
        _sig(1033, 0.50, 0.62), // 真正的切换帧
        _sig(1067, 0.31, 0.46),
      ]);

      expect(got, hasLength(1));
      expect(got.single.ms, 1033);
    });

    test('确认的切点优先于灰区切点被保留', () {
      final got = _detector.detect([
        _sig(1000, 0.12, 0.20), // 灰区
        _sig(1100, 0.50, 0.60), // 确认
      ]);

      expect(got, hasLength(1));
      expect(got.single.ms, 1100);
      expect(got.single.isConfirmed, isTrue);
    });

    test('间隔达到最短镜头时长就都保留', () {
      final got = _detector.detect([
        _sig(1000, 0.50, 0.60),
        _sig(1400, 0.50, 0.60),
      ]);

      expect(got.map((c) => c.ms), [1000, 1400]);
    });

    test('几帧长的碎片不会被切出来', () {
      final got = _detector.detect([
        for (var ms = 1000; ms < 1300; ms += 33) _sig(ms, 0.5, 0.6),
      ]);

      expect(got, hasLength(1),
          reason: '短视频广告里几帧长的「镜头」没有产品意义，'
              '只会让用户多点几次合并');
    });
  });

  group('平稳画面不产生切点', () {
    test('全片没有变化时一个切点都没有', () {
      final got = _detector.detect([
        for (var ms = 0; ms < 10000; ms += 33) _sig(ms, 0.005, 0.03),
      ]);

      expect(got, isEmpty);
    });

    test('空输入不炸', () {
      expect(_detector.detect(const []), isEmpty);
    });
  });

  group('直方图计算', () {
    test('纯色图的距离为 0，黑白两图距离达到上界附近', () {
      final black = histogramOfRgb24(List<int>.filled(32 * 32 * 3, 0));
      final black2 = histogramOfRgb24(List<int>.filled(32 * 32 * 3, 0));
      final white = histogramOfRgb24(List<int>.filled(32 * 32 * 3, 255));

      expect(histogramDistance(black, black2), 0);
      expect(histogramDistance(black, white), closeTo(2, 0.01),
          reason: '取值范围 0~2（黑白两极端），实测素材上 p99 落在 0.47~0.56、'
              '最大 1.2。阈值就是按这个口径标定的，改除数会让标定数据全废');
    });

    test('归一化后各通道的和为 1，与图像尺寸无关', () {
      final h = histogramOfRgb24(List<int>.filled(32 * 32 * 3, 100));

      expect(h.sublist(0, histBinsPerChannel).reduce((a, b) => a + b),
          closeTo(1, 1e-9));
    });

    test('长度不一致或空直方图返回 0，不抛异常', () {
      expect(histogramDistance(const [], const []), 0);
      expect(histogramDistance(const [1, 0], const [1]), 0);
    });
  });
}
