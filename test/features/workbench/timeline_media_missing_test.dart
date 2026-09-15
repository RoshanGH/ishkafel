import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';

/// 抽帧失败只写日志、照常返回一份「全是 null 的列表」，波形失败返回
/// 「全 0 的列表」——两条轨于是画成一片空白，而状态报的是「已就绪」，
/// 界面一个字都不说。
///
/// 这正是 CLAUDE.md 禁的那一类静默降级：用户看到的是「这栏是不是坏了」，
/// 而日志里躺着真正的原因（2026-09-15 真机：「这个音频和画面轨是空的？」）。
void main() {
  TimelineMedia media({List<String?>? thumbs, List<double>? wave}) =>
      TimelineMedia(
        thumbPaths: thumbs ?? ['/a.jpg', '/b.jpg'],
        waveEnvelope: wave ?? [0.1, 0.8, 0.3],
      );

  group('画面轨自陈', () {
    test('一张都没抽出来：说得出来「全没有」', () {
      expect(media(thumbs: [null, null, null]).thumbsAllMissing, isTrue);
    });

    test('抽到几张就不算全没有——那条轨还有东西可画', () {
      expect(media(thumbs: [null, '/b.jpg', null]).thumbsAllMissing, isFalse);
    });

    test('报得出缺几张：界面要照着它说话', () {
      expect(media(thumbs: [null, '/b.jpg', null]).thumbsMissing, 2);
    });

    test('空列表也算全没有', () {
      expect(media(thumbs: const []).thumbsAllMissing, isTrue);
    });

    test('全抽到了就是好的', () {
      expect(media().thumbsAllMissing, isFalse);
      expect(media().thumbsMissing, 0);
    });
  });

  group('音频轨自陈', () {
    test('全 0 就是没算出来——不是「这段真的没声音」', () {
      expect(media(wave: [0, 0, 0, 0]).waveAllSilent, isTrue,
          reason: '失败兜底返回的正是全 0，只判 isEmpty 会漏掉');
    });

    test('有一根柱子就算算出来了', () {
      expect(media(wave: [0, 0, 0.02, 0]).waveAllSilent, isFalse);
    });

    test('空列表也算没算出来', () {
      expect(media(wave: const []).waveAllSilent, isTrue);
    });

    test('正常波形是好的', () {
      expect(media().waveAllSilent, isFalse);
    });
  });
}
