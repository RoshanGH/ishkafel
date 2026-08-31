import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 慢步骤必须**报进度，而且带分母**。
///
/// 用户的原话：「中间等待的时候软件上要播报 agent 在干什么，让用户有明确
/// 感知。最重要的点是让用户知道进度——虽然在等待，但知道进度在往前走，
/// 解决用户的焦虑：你在干什么、有没有卡死。」
///
/// 参考片打标是全流程里最难熬的一段：25 句、47 个参考镜、十几分钟，
/// 每一镜一次付费识图。而它此前**一声不吭**——验收时人在旁边看着，
/// 界面停在任务列表、任务缩略图还是黑的，十四分钟里没有任何东西动过。
/// 那是整条流程里唯一一段纯黑屏，也是最烧钱的一段。
///
/// 「正在打标」不够。人要的是**看着数字往前走**，所以分母要按整片算，
/// 不是按这一行算——tag-ref 是按行调用的，只报「这一行第 2/3 镜」，
/// 人还是不知道整件事走到哪了。
void main() {
  final src = File('lib/cli/commands/script_command.dart').readAsStringSync();

  test('打标这一步会播报', () {
    expect(src, contains('runScriptTagRefCommand'), reason: '命令还在吧');
    final body = src.substring(src.indexOf('Future<int> runScriptTagRefCommand'));
    expect(body, contains('AgentStage'),
        reason: '十四分钟、47 次识图，全程一声不吭——'
            '人不知道它在干什么，也不知道是不是卡死了');
    expect(body, contains('stage.show'),
        reason: '光开个场不够，每打一镜都要说一声，人才看得出在往前走');
  });

  test('进度要有整片的分母，不是只报这一行', () {
    expect(src, contains('_refShotCount'),
        reason: 'tag-ref 是按行调用的。只报「这一行第 2/3 镜」的话，'
            '人还是不知道整件事走到哪了——要的是一个一路涨到头的数字');
    expect(src, contains('_taggedRefShotCount'),
        reason: '跨调用也要接得上：这次是从第 23 镜接着往下，不是从 0 重来');
    expect(src, contains('全片'),
        reason: '话要说人话：「全片 23/47 镜」');
  });

  test('打标时界面要跟到那一行', () {
    final body = src.substring(src.indexOf('Future<int> runScriptTagRefCommand'));
    expect(body, contains('AgentFocus'),
        reason: '说了在看第 12 句，界面就该停在第 12 句上');
    expect(body, contains("module: 'director'"),
        reason: '此前它从没让界面进过那个任务——人一直看着任务列表');
  });

  test('配音那条早就这么做了，别退化', () {
    final run =
        File('lib/cli/commands/script_run_command.dart').readAsStringSync();
    expect(run, contains('/\${targets.length}'),
        reason: '配音的「（19/25）」是这套东西的样板');
  });
}
