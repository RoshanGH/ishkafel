import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/analysis_progress.dart';

void main() {
  group('阶段文案', () {
    test('每个阶段都有面向用户的中文说明，不出现技术黑话', () {
      const jargon = ['PCM', 'ASR', 'ffmpeg', 'API', 'JSON'];
      for (final stage in AnalysisStage.values) {
        final label = AnalysisProgress(stage: stage).label;
        expect(label, isNotEmpty, reason: '$stage 缺少文案');
        for (final word in jargon) {
          expect(label.toUpperCase(), isNot(contains(word)),
              reason: '「$label」里出现了 $word——用户看的是进度，不是日志');
        }
      }
    });

    test('阶段序号从 1 开始且覆盖全部阶段', () {
      expect(const AnalysisProgress(stage: AnalysisStage.extractingAudio).stageNumber, 1);
      expect(const AnalysisProgress(stage: AnalysisStage.taggingShots).stageNumber,
          AnalysisStage.values.length);
      expect(AnalysisProgress.stageCount, AnalysisStage.values.length);
    });
  });

  group('子项计数', () {
    test('有计数的阶段把「第几个 / 共几个」写进详情', () {
      const p = AnalysisProgress(
          stage: AnalysisStage.taggingShots, done: 12, total: 32);

      expect(p.detail, contains('12'));
      expect(p.detail, contains('32'));
    });

    test('没有计数的阶段不编造「0 / 0」', () {
      const p = AnalysisProgress(stage: AnalysisStage.transcribing);

      expect(p.detail, isNull,
          reason: '显示「0 / 0」会被读成「一个都没完成」，比不显示更糟');
    });

    test('计数阶段给出可用于进度条的比例', () {
      expect(
          const AnalysisProgress(
                  stage: AnalysisStage.taggingShots, done: 8, total: 32)
              .fraction,
          0.25);
    });

    test('无计数阶段的比例为 null——进度条该是不确定态而不是停在 0%', () {
      expect(const AnalysisProgress(stage: AnalysisStage.transcribing).fraction,
          isNull,
          reason: '一根卡在 0% 的确定态进度条，看起来就是「卡死了」');
    });

    test('total 为 0 时不做除零', () {
      expect(
          const AnalysisProgress(
                  stage: AnalysisStage.taggingShots, done: 0, total: 0)
              .fraction,
          isNull);
    });
  });

  group('一句话摘要（任务卡上只有一行的位置）', () {
    test('带计数时把阶段与进度合成一行', () {
      const p = AnalysisProgress(
          stage: AnalysisStage.taggingShots, done: 12, total: 32);

      expect(p.summary, contains(p.label));
      expect(p.summary, contains('12'));
    });

    test('不带计数时就是阶段本身，不留一个空括号', () {
      const p = AnalysisProgress(stage: AnalysisStage.transcribing);

      expect(p.summary, p.label);
      expect(p.summary, isNot(contains('(')));
      expect(p.summary, isNot(contains('（')));
    });
  });

  group('相等性（界面靠它判断要不要重绘）', () {
    test('同阶段同计数视为相等', () {
      expect(
          const AnalysisProgress(
              stage: AnalysisStage.taggingShots, done: 1, total: 2),
          const AnalysisProgress(
              stage: AnalysisStage.taggingShots, done: 1, total: 2));
    });

    test('计数变化即不等', () {
      expect(
          const AnalysisProgress(
              stage: AnalysisStage.taggingShots, done: 1, total: 2),
          isNot(const AnalysisProgress(
              stage: AnalysisStage.taggingShots, done: 2, total: 2)));
    });
  });
}
