import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/agent_skill/agent_skill_doc.dart';

/// **人在界面上能拧的每一个旋钮，Agent 都要能拧。**
///
/// 用户定的形状：软件提供能力，Agent 调用这些能力**并自己做判断**——
/// 用标签搜、用台词 ASR 搜、用画面描述搜、用参考图搜，用哪一种、带哪些
/// 标签，都由使用者在对话框里交待给 Agent，再由 Agent 决定。
/// 软件不替它做主。
///
/// 反面是真机上撞到的那一幕：Codex 已经停了，界面还在一句句地铺——
/// 「这说明找镜头这个动作根本不是 Agent 在做，是它敲了一条命令，
/// 然后软件自己在跑。」
///
/// 找镜头面板上人能动的是三样：**检索方式**、**关键词/参考图**、
/// **标签（可加可减）**。少一样，Agent 就只能被动接受软件给的默认值。
void main() {
  test('五种检索方式都给了 Agent', () {
    final src = File('lib/cli/search_modes.dart').readAsStringSync();
    for (final mode in ['tags', 'content', 'image', 'voiceover', 'name']) {
      expect(src, contains("'$mode'"), reason: '界面上有的检索方式，命令行也要有');
    }
  });

  test('标签能由 Agent 指定——这是面板上人动得最多的那个旋钮', () {
    final src = File('lib/cli/commands/script_command.dart').readAsStringSync();
    expect(src, contains('searchTags'),
        reason: '人在面板上第一件事就是把不合适的标签去掉、把想要的加上；'
            'Agent 只能被动接受参考镜打出来的那几个，等于少了最关键的旋钮');
    expect(src, contains('wantTags'),
        reason: '给了就得真的用上，不能收下参数又走默认');
  });

  test('标签词表要给出来——不知道有哪些，就无从「加上想要的」', () {
    final src = File('lib/cli/commands/import_command.dart').readAsStringSync();
    expect(src, contains("'tags': g.tags"),
        reason: 'tag-groups 只报组名的话，Agent 不知道组里有哪些标签可选');
  });

  test('手册要教它这个旋钮怎么用', () {
    expect(agentSkillMarkdown, contains('--tags'),
        reason: '能力给了不写进手册，等于没给');
    expect(agentSkillMarkdown, contains('公共筛选层'),
        reason: '要说清标签不是某一种检索方式，而是贴在每一种上的约束');
  });

  test('Agent 在场时，界面不许自作主张替它把活干了', () {
    final src =
        File('lib/features/director/director_page.dart').readAsStringSync();
    final offer = src.substring(src.indexOf('_offerDraftAfterExtract'));
    expect(offer.substring(0, 900), contains('_agent != null'),
        reason: '「自动铺一版」是给人自己用的：软件把空位全填满。'
            'Agent 干活时还弹它，人看到的就是「Agent 停了，软件还在跑」');
  });

  test('界面自己跑的长任务要能叫停', () {
    final src =
        File('lib/features/director/director_page.dart').readAsStringSync();
    expect(src, contains('_draftCancelled'),
        reason: '自动铺片一次几十句配音加几十次识图、十几分钟起步，'
            '跑起来却没有任何停下来的办法——人只能看着它把钱烧完');
    expect(src, contains('_cancelDraft()'),
        reason: '人按「我来接手」时，界面自己在跑的那摊也要停');
  });

  group('结果要一格格长出来，不是全做完再刷一下', () {
    // 用户反复说的：「第二个镜头里面有 11 个分镜，你就应该每找一个这就多出
    // 一个，它是一步一步的，不能全部执行完以后你再刷新一下。」
    //
    // 界面是靠读盘跟上进度的——CLI 攒到整批才写一次盘，界面再怎么刷新也
    // 看不到中间态。根子在**落盘的粒度**，不在界面。
    test('打标：每打完一镜就落盘', () {
      final src =
          File('lib/cli/commands/script_command.dart').readAsStringSync();
      final body =
          src.substring(src.indexOf('Future<int> runScriptTagRefCommand'));
      final loop = body.substring(body.indexOf('taggedSoFar++'));
      expect(loop.substring(0, 500), contains('repository.save'),
          reason: '攒到整行才写，人看到的是「播报都到第 7 镜了，'
              '画面上一个都没出现」，然后忽然整行刷出来');
    });

    test('挑镜头：每落一行就写一次盘', () {
      final src = File('lib/cli/commands/script_apply_command.dart')
          .readAsStringSync();
      expect(src, contains('onLineDone'),
          reason: 'Agent 就算一次提交十几行，界面也该一行行长出来');
      expect(src, contains('await onLineDone?.call(next)'),
          reason: '钩子留了却不在每行调用，等于没留');
    });
  });

  test('拿参考镜首帧搜——界面有的，命令行也要有', () {
    // 人在参考镜卡上点「画面相似」，Agent 也得能做同一件事。
    // 此前那套上传查询帧的逻辑只接在界面上，命令行只能拿**候选素材**的
    // fileKey 搜——手里攥着要复刻的那一帧却用不上，正是这条线最该用的路
    final modes = File('lib/cli/search_modes.dart').readAsStringSync();
    expect(modes, contains("'ref-image'"),
        reason: '界面能拿参考镜首帧搜，命令行不能，就是少了一个旋钮');
    final cmd = File('lib/cli/commands/script_command.dart').readAsStringSync();
    expect(cmd, contains('_searchLikeRefFrame'));
    expect(cmd, contains('QueryFrameUploader'),
        reason: '以图搜视频只吃 OSS key，本地帧要先传成查询帧');
  });

  test('今天改的行为都写进手册了', () {
    for (final k in [
      '--by ref-image', // 拿参考镜首帧搜
      '提取台词时就定下来了', // extract 自动定音色
      '没配音的行，挑不了画面', // shots 的硬拦截
      '从参考片提取时会自动产生这种行', // 无台词段成画面行
      'voice-file', // 用自己录的配音
    ]) {
      expect(agentSkillMarkdown, contains(k),
          reason: '「$k」这条行为变了却没写进手册——Agent 照旧的做法会撞墙');
    }
  });
}
