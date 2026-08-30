import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **人能看到的信息，Agent 也要拿得到。**
///
/// 这个项目的原则是「所有人能干的事情 Agent 都要有能力去干」，但验收 Agent
/// 撞到的是它的反面：
///
/// - 走委派提交方案时，界面上那条橙色警告人看得见，Agent 的返回里没有
/// - `review list` 只给一个素材 id：人在审片台上看得到画面、能一眼看出
///   「这条烧着字」，Agent 拿到的是个数字。人问「第 3 条是什么」它答不上来
/// - `candidates` 里没有画面自查结果：人挑素材时当场就能看到，
///   Agent 只能先提交、等 `apply` 报错再回去重挑——「人挑一次，我挑两次」
///
/// 这三条都不是「功能没做」，是**做了但只给了人**。
void main() {
  _exportTests();
  String read(String path) => File(path).readAsStringSync();

  test('提交方案的返回里，会毁掉整片的两条都要有', () {
    final apply = read('lib/cli/commands/apply_command.dart');
    expect(apply, contains('planApplyReport'),
        reason: '两条路要给同一份报告，各拼各的迟早只有一份是全的');
  });

  test('审核列表要说清每条是什么，不是只给一个 id', () {
    final review = read('lib/cli/commands/review_command.dart');
    for (final field in ['name', 'burnedText', 'productBrand']) {
      expect(review, contains("'$field'"),
          reason: '`review list` 里没有 $field。人在审片台上看得见画面，'
              'Agent 拿到的却是个数字——人问「第 3 条是什么」它答不上来');
    }
  });

  test('挑素材时就要能看到已经查过的画面问题', () {
    final candidates = read('lib/cli/commands/candidates_command.dart');
    expect(candidates, contains('frameChecks'),
        reason: '`candidates` 里没有画面自查结果。Agent 只能先提交、'
            '等 apply 报错再回来重挑——人挑一次，它挑两次');
    // 但不许为了这个在检索时现查：一页 50 条各跑一次视觉调用太贵
    expect(candidates, isNot(contains('defaultShotFrameCheck')),
        reason: '检索时不许现查画面——一页 50 条就是 50 次视觉调用。'
            '只报缓存里已经知道的');
  });

  test('查过的结果跨任务复用——一条素材看一次，不是每个任务看一次', () {
    expect(read('lib/core/ai/frame_check_wiring.dart'), contains('cache.get'),
        reason: '不看缓存就直接花钱看，是拿钱换一个已经知道的答案');
  });
}

/// 导出是花钱花时间的最后一步，出来的就是要交付的片子。
/// 界面上的确认页会点名有问题的素材——纯命令行那条路不能一声不吭。
void _exportTests() {
  test('导出前要说清这批素材有什么问题', () {
    final export =
        File('lib/cli/commands/export_command.dart').readAsStringSync();
    expect(export, contains('exportWarnings'),
        reason: '`export` 对烧字和品牌错位一声不吭。Agent 查得到'
            '（task --json 里有），导出时不提，等于把「要不要用这条素材」'
            '这个判断悄悄跳过了');
  });

  test('剪映导出同理——那也是一份要交付的东西', () {
    final jianying =
        File('lib/cli/commands/jianying_command.dart').readAsStringSync();
    expect(jianying, contains('exportWarnings'),
        reason: '写进剪映草稿的素材同样可能烧着别家的字、露着竞品');
  });
}
