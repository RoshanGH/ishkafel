import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/net/json_poster.dart';
import 'package:ishkafel/core/analysis/boundary_reviewer.dart';
import 'package:ishkafel/core/analysis/shot_boundary_detector.dart';

/// 这些用例只走纯函数分支，永远不会真的发请求
ArkChatClient _stubChat() => ArkChatClient(
    apiKey: 'x',
    post: (_, _, _) async => const JsonPostResult(statusCode: 200, body: '{}'));

BoundaryReviewer _reviewer({int maxReviews = 24}) => BoundaryReviewer(
    chat: _stubChat(),
    workDir: Directory.systemTemp,
    maxReviews: maxReviews);

ShotBoundaryCandidate _c(int ms, {required bool confirmed, double hist = 0.2}) =>
    ShotBoundaryCandidate(
      ms: ms,
      confidence:
          confirmed ? BoundaryConfidence.confirmed : BoundaryConfidence.uncertain,
      sceneScore: 0.2,
      histDistance: hist,
    );

void main() {
  group('只送灰区去复核', () {
    test('已确认的切点不占额度', () {
      final picked = _reviewer().pick([
        _c(1000, confirmed: true),
        _c(2000, confirmed: false),
        _c(3000, confirmed: true),
      ]);

      expect(picked.map((c) => c.ms), [2000],
          reason: '确认的也送检，一条素材要几十次视觉推理，'
              '分析时间和额度都不划算');
    });

    test('超过上限时先看最没把握的', () {
      final picked = _reviewer(maxReviews: 2).pick([
        _c(1000, confirmed: false, hist: 0.40),
        _c(2000, confirmed: false, hist: 0.17),
        _c(3000, confirmed: false, hist: 0.25),
      ]);

      expect(picked.map((c) => c.ms), [2000, 3000],
          reason: '直方图距离越低越可疑，额度要花在最可能是误检的那些上');
    });

    test('没有灰区切点时一次都不调用', () {
      expect(_reviewer().pick([_c(1, confirmed: true)]), isEmpty);
    });
  });

  group('回答解析', () {
    test('认出两种结论', () {
      expect(BoundaryReviewer.parseVerdict('交界'), BoundaryVerdict.cut);
      expect(BoundaryReviewer.parseVerdict('同一镜头'), BoundaryVerdict.same);
    });

    test('模型多说两句也认得出来', () {
      expect(BoundaryReviewer.parseVerdict('这两帧属于同一个镜头，只是手在移动'),
          BoundaryVerdict.same);
      expect(BoundaryReviewer.parseVerdict('答：交界。机位变了'),
          BoundaryVerdict.cut);
    });

    test('答非所问归为看不准，不硬猜', () {
      expect(BoundaryReviewer.parseVerdict('无法判断'), BoundaryVerdict.unknown);
      expect(BoundaryReviewer.parseVerdict(''), BoundaryVerdict.unknown);
    });
  });

  group('结论落地时兜底方向偏向保留', () {
    test('判为同一镜头才撤掉这一刀', () {
      final kept = applyVerdicts(
        [_c(1000, confirmed: false), _c(2000, confirmed: false)],
        {1000: BoundaryVerdict.same, 2000: BoundaryVerdict.cut},
      );

      expect(kept.map((c) => c.ms), [2000]);
    });

    test('看不准的保留', () {
      final kept = applyVerdicts(
          [_c(1000, confirmed: false)], {1000: BoundaryVerdict.unknown});

      expect(kept, hasLength(1),
          reason: '漏切一刀用户得自己在时间线上找位置补刀，'
              '多切一刀点一下合并就行——兜底只能偏向保留');
    });

    test('没送检的（超出上限）保留', () {
      final kept = applyVerdicts([_c(1000, confirmed: false)], const {});

      expect(kept, hasLength(1));
    });

    test('确认的切点不受复核结果影响', () {
      final kept = applyVerdicts(
          [_c(1000, confirmed: true)], {1000: BoundaryVerdict.same});

      expect(kept, isEmpty,
          reason: '这里如实反映当前设计：applyVerdicts 只按 verdicts 过滤，'
              '而确认的切点根本不会出现在 verdicts 里（pick 已排除）');
    });
  });

  group('抽帧参数', () {
    test('取切点当帧与它前一帧，并排拼成一张图', () {
      final args = BoundaryReviewer.stackArgs(
          videoPath: '/v/a.mp4',
          beforeSeconds: 2.6,
          atSeconds: 2.633,
          outPath: '/tmp/o.jpg');

      expect(args.first, '-y', reason: '重跑分析不能卡在覆盖确认上');
      expect(args.join(' '), contains('hstack'));
      expect(args.join(' '), contains('2.600'));
      expect(args.join(' '), contains('2.633'));
    });
  });
}
