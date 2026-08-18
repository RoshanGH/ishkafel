import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/candidate_probe.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_failure.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/picking/candidate_panel.dart';
import 'package:ishkafel/features/picking/candidate_search_controller.dart';
import 'package:ishkafel/features/picking/picking_controller.dart';
import 'package:ishkafel/features/picking/picking_scope.dart';

/// 检索失败必须「有名字、有动作」：登录失效给「重新登录」，其余给「重试」。
/// 一句红字挂在那儿没有任何按钮，等于把用户困在原地——这正是妙啊连接
/// 目标里「其余一切故障都必须有名字、有动作」那一条。
void main() {
  CandidateSearchController controllerFailing(String stderr) =>
      CandidateSearchController(
        service: MiaoaContentService(
            gateway: MiaoaGateway(
                run: (_, _) async => ProcessResult(1, 1, '', stderr),
                binary: 'miaoa')),
        probe: CandidateProbe(run: (_, _) async => ProcessResult(1, 1, '', '')),
      );

  PickingScope scope() => const PickingScope(
        tagNames: [],
        tagIds: [],
        targetDurationMs: 5000,
        descriptionKeyword: '词',
        descriptionSupported: true,
        tagUnavailableText: null,
      );

  Future<void> pump(
    WidgetTester tester,
    CandidateSearchController search, {
    VoidCallback? onRelogin,
    VoidCallback? onRetrySearch,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CandidatePanel(
            // 保留原片模式下面板只显示引导语——失败提示是替换模式下的事
            picking: PickingController(units: const [
              SemanticUnit(index: 0, startMs: 0, endMs: 5000, transcript: '词'),
            ])
              ..setMode(ReplacementMode.whole),
            search: search,
            scope: scope(),
            searchMode: CandidateSearchMode.description,
            onSearchModeChanged: (_) {},
            onModeChanged: (_) {},
            onViewChanged: (_) {},
            onRelogin: onRelogin,
            onRetrySearch: onRetrySearch,
          ),
        ),
      ));

  testWidgets('登录失效 → 「重新登录」按钮，点了走对症入口', (tester) async {
    final search = controllerFailing('HTTP 401 unauthorized');
    await search.searchByDescription('喷雾');
    expect(search.failureKind, MiaoaFailureKind.unauthorized);

    var relogins = 0;
    await pump(tester, search, onRelogin: () => relogins++, onRetrySearch: () {});

    expect(find.byKey(const ValueKey('candidate-relogin')), findsOneWidget);
    expect(find.byKey(const ValueKey('candidate-retry-search')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('candidate-relogin')));
    expect(relogins, 1);
  });

  testWidgets('网络失败 → 「重试」按钮，点了原样重发', (tester) async {
    final search = controllerFailing('dial tcp: i/o timeout');
    await search.searchByDescription('喷雾');
    expect(search.failureKind, MiaoaFailureKind.network);

    var retries = 0;
    await pump(tester, search, onRetrySearch: () => retries++);

    expect(find.byKey(const ValueKey('candidate-retry-search')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('candidate-retry-search')));
    expect(retries, 1);
  });

  test('controller.retry 原样重发上一次检索——登录回来后一键恢复', () async {
    var calls = 0;
    var broken = true;
    final search = CandidateSearchController(
      service: MiaoaContentService(
          gateway: MiaoaGateway(
              run: (_, _) async {
                calls++;
                if (broken) return ProcessResult(1, 1, '', '401 unauthorized');
                return ProcessResult(
                    1, 0, '{"records":[],"total":0}', '');
              },
              binary: 'miaoa')),
      probe: CandidateProbe(run: (_, _) async => ProcessResult(1, 1, '', '')),
    );

    await search.searchByDescription('喷雾');
    expect(search.status, CandidateSearchStatus.failed);

    broken = false;
    await search.retry();
    expect(search.status, CandidateSearchStatus.ready);
    expect(calls, 2);
  });

  test('没检索过就 retry：静默返回，不炸', () async {
    final search = controllerFailing('x');
    await search.retry();
    expect(search.status, CandidateSearchStatus.idle);
  });
}
