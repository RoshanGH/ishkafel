import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/agent_skill/agent_skill_doc.dart';

/// 对着这份手册干活的人是**编导或剪辑，不是工程师**。
///
/// 他不会说「先跑 `ishkafel skill --install`」，也不会说
/// 「`export ISHKAFEL_APP=...`」——他把手册粘给 Agent，然后说
/// 「我这有个视频，帮我做成结构一样、画面全新的片子，用可视化模式」。
///
/// **环境的事得手册自己兜住**：命令不存在怎么办、软件在哪、怎么装。
/// 兜不住就等于要求编导先学会一套命令行知识，那这个交付路径根本走不通。
void main() {
  test('手册认得编导嘴里的说法，不是只认 --visual', () {
    for (final phrase in ['可视化', '我看着']) {
      expect(agentSkillMarkdown, contains(phrase),
          reason: '人说「$phrase」时 Agent 要知道那就是可视模式。'
              '他不会说 --visual——那是 Agent 自己的事');
    }
  });

  test('手册开篇就兜住「敲 ishkafel 说没这个命令」', () {
    final head = agentSkillMarkdown.substring(0, 2000);
    expect(head, contains('没这个命令'),
        reason: '编导粘完手册就走了。命令不存在时 Agent 得自己知道'
            '去哪儿装，不能反过来要人给它配环境');
    expect(head, contains('设置'),
        reason: '要给出能让人点的地方（app 的设置页），'
            '不是让人去敲另一条命令');
  });

  test('手册说的那个安装入口，界面上真的有', () {
    // 这一轮反复栽的就是「手册说了但实际没有」
    expect(agentSkillMarkdown, contains('命令行工具'));
    expect(agentSkillMarkdown, contains('运行环境'));
  });
}
