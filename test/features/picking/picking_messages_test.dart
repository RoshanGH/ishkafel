import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart' show MiaoaException;
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/picking/picking_messages.dart';

void main() {
  group('组合数状态栏', () {
    test('把各单元因子摊开显示，用户能看出是哪一层把数撑起来的', () {
      final plan = ReplacementPlan([
        UnitReplacement.whole([1, 2]),
        UnitReplacement.keepOriginal(),
        UnitReplacement.perShot({
          0: [1, 2],
          1: [3, 4, 5],
        }),
      ]);
      expect(combinationSummaryText(plan), '当前组合 2 × 1 × 6 = 12 条 / 上限 100');
    });

    test('单元很多时不摊开因子（状态栏一行放不下，摊开等于什么都没说清）', () {
      final plan = ReplacementPlan(
          List.generate(20, (_) => UnitReplacement.keepOriginal()));
      expect(combinationSummaryText(plan), '当前组合 1 条 / 上限 100');
    });

    test('超限时状态栏如实显示条数而不是显示饱和哨兵值', () {
      final plan = ReplacementPlan([
        UnitReplacement.whole(List.generate(11, (i) => i)),
        UnitReplacement.whole(List.generate(11, (i) => 100 + i)),
      ]);
      expect(combinationSummaryText(plan), contains('121 条'));
    });
  });

  group('导出前的阻断与提醒（不能留一个点不动又不解释的按钮）', () {
    test('未超限时不阻断', () {
      expect(exportBlockedReason(ReplacementPlan([UnitReplacement.whole([1, 2])])),
          isNull);
    });

    test('超限时说清超了多少、该从哪个单元减', () {
      final plan = ReplacementPlan([
        UnitReplacement.whole(List.generate(11, (i) => i)), // 11
        UnitReplacement.whole(List.generate(11, (i) => 100 + i)), // 11
      ]);
      final reason = exportBlockedReason(plan)!;
      expect(reason, contains('121'));
      expect(reason, contains('21'), reason: '要说清超出上限多少条');
      expect(reason, contains('U1'), reason: '要指到具体的台词语义单元');
    });

    test('组合数荒谬到无法精确统计时也要给一句人话，不能显示天文数字', () {
      final huge = ReplacementPlan(
          List.generate(60, (_) => UnitReplacement.whole([1, 2])));
      final reason = exportBlockedReason(huge)!;
      expect(reason, contains('远超上限'));
      expect(reason, isNot(contains('e+')));
    });

    test('一条替换都没设置时给提醒，但不阻断（用户可能就是想先导一条原片）', () {
      final empty = ReplacementPlan([UnitReplacement.keepOriginal()]);
      expect(exportBlockedReason(empty), isNull);
      expect(emptyPlanNotice, contains('与原片相同'));
    });
  });

  group('检索返回 0 条的引导（「库里没有」与「标签没打上」是两回事）', () {
    test('标签检索但这个镜头没有标签：引导去补标签或换检索方式', () {
      final text = emptyResultGuidance(
          mode: CandidateSearchMode.tag, queryTagCount: 0);
      expect(text, contains('还没有'));
      expect(text, contains('标签'));
      expect(text, contains('画面描述'));
    });

    test('标签检索且带了标签：说明是素材库里确实没有，引导放宽条件', () {
      final text = emptyResultGuidance(
          mode: CandidateSearchMode.tag, queryTagCount: 2);
      expect(text, contains('素材库'));
      expect(text, contains('放宽'));
    });

    test('画面描述与首帧搜图各自给出对应的下一步', () {
      expect(
          emptyResultGuidance(
              mode: CandidateSearchMode.description, queryTagCount: 0),
          contains('换个说法'));
      expect(
          emptyResultGuidance(mode: CandidateSearchMode.image, queryTagCount: 0),
          contains('换一帧'));
    });
  });

  group('标签检索不可用的原因（不能给个点不动的灰按钮）', () {
    test('任务没选视觉镜头标签组：说清是新建任务时没选，并给替代路径', () {
      final reason =
          tagSearchDisabledReason(hasShotTagGroup: false, queryTagCount: 0)!;
      expect(reason, contains('标签组'));
      expect(reason, contains('首帧搜图'));
    });

    test('选了标签组但这个镜头没打上标签：只说这一条', () {
      final reason =
          tagSearchDisabledReason(hasShotTagGroup: true, queryTagCount: 0)!;
      expect(reason, contains('没有标签'));
      expect(reason, isNot(contains('标签组')));
    });

    test('标签齐备时可用', () {
      expect(tagSearchDisabledReason(hasShotTagGroup: true, queryTagCount: 3),
          isNull);
    });
  });

  group('检索失败提示：服务层已经给了中文，不许再包一层前缀', () {
    test('miaoa 失败原样透出', () {
      expect(
          describeSearchFailure(
              const MiaoaException('素材库登录已失效，请在终端执行 miaoa auth login 后重试')),
          '素材库登录已失效，请在终端执行 miaoa auth login 后重试');
    });

    test('CLI 未安装：透出安装引导，不加「未知错误」之类的壳', () {
      final text = describeSearchFailure(const MediaToolMissingException('miaoa'));
      expect(text, contains('miaoa auth login'));
      expect(text, isNot(contains('未知')));
      expect(text, isNot(contains('Exception')));
    });

    test('陌生异常给通用中文，绝不把原始异常文本摊给用户', () {
      final text = describeSearchFailure(StateError('Bad state: no element'));
      expect(text, isNot(contains('Bad state')));
      expect(text, contains('请稍后重试'));
    });
  });

  group('候选卡的时长与时长差（探测不到就不显示，不能拿假数据糊弄）', () {
    test('时长文案保留一位小数', () {
      expect(candidateDurationText(6840), '6.8s');
    });

    test('规格未探测到时不出时长差徽标', () {
      expect(durationDeltaText(candidateMs: null, targetMs: 6200), isNull);
    });

    test('目标时长非法时同样不出徽标（0 会算出「差 100%」的假徽标）', () {
      expect(durationDeltaText(candidateMs: 6800, targetMs: 0), isNull);
    });

    test('长了标 +、短了标 −（真减号，不是连字符）', () {
      expect(durationDeltaText(candidateMs: 6840, targetMs: 6240), '+0.6');
      expect(durationDeltaText(candidateMs: 5900, targetMs: 6240), '−0.3');
    });

    test('差不到 0.05 秒时不出徽标（视觉噪声）', () {
      expect(durationDeltaText(candidateMs: 6240, targetMs: 6240), isNull);
    });
  });

  group('因子小结（右栏底部那一行）', () {
    test('镜头级：报当前镜头的选中数与整单元的因子算式', () {
      final text = selectionSummaryText(
        unitIndex: 2,
        shotIndex: 1,
        selectedCount: 3,
        totalCount: 18,
        replacement: UnitReplacement.perShot({
          0: [1, 2],
          1: [3, 4, 5],
        }),
        shotCount: 3,
      );
      // 算式按镜头顺序排（S1 × S2 × S3），未选的镜头计 1。设计稿示例里写的是
      // 「2×1×3」而镜头条上是 S1 ×2 / S2 ×3 / S3 原片——设计稿本身把顺序写反了，
      // 这里以镜头顺序为准，否则用户对不上是哪个镜头贡献了哪个数。
      expect(text, 'S2 已选 3 / 18 条 · U3 因子 = 2 × 3 × 1 = 6');
    });

    test('整体替换：报单元自己的选中数与因子', () {
      final text = selectionSummaryText(
        unitIndex: 0,
        shotIndex: null,
        selectedCount: 2,
        totalCount: 18,
        replacement: UnitReplacement.whole([1, 2]),
        shotCount: 3,
      );
      expect(text, 'U1 已选 2 / 18 条 · U1 因子 = 2');
    });

    test('保留原片：不报选中数，只说明这一单元不参与替换', () {
      final text = selectionSummaryText(
        unitIndex: 0,
        shotIndex: null,
        selectedCount: 0,
        totalCount: 0,
        replacement: UnitReplacement.keepOriginal(),
        shotCount: 3,
      );
      expect(text, 'U1 保留原片 · 因子 = 1');
    });
  });
}
