import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/agent_broadcast.dart';

/// Agent 干活时的**播报流**：它现在在做什么，刚才做了什么。
///
/// 用户要的：「下面有一个播报——Agent 正在新建任务、正在给第三行找视频、
/// 正在给第 3~15 行配背景音乐……只保留最近 5 条，最起码 0.5 秒过一个，
/// 让我能看清字。」
///
/// 为什么不是现在那条横幅：横幅只显示当前一条，下一步一到就被覆盖，
/// 切太快等于没有。播报流解决的是「我刚走神了，它这几步做了什么」。
void main() {
  test('最新的一条排在最后——视线落在底部，像聊天记录', () {
    final b = AgentBroadcast.empty
        .push('正在新建任务')
        .push('正在提取台词');
    expect(b.lines.last.text, '正在提取台词');
    expect(b.lines.first.text, '正在新建任务');
  });

  test('只留最近 5 条——再多就成了刷屏，人根本读不过来', () {
    var b = AgentBroadcast.empty;
    for (var i = 1; i <= 8; i++) {
      b = b.push('第 $i 步');
    }
    expect(b.lines, hasLength(5));
    expect(b.lines.first.text, '第 4 步');
    expect(b.lines.last.text, '第 8 步');
  });

  test('同一句话连着来不重复排——重试和轮询会把真正的动作淹掉', () {
    final b = AgentBroadcast.empty
        .push('正在给第 3 行找镜头')
        .push('正在给第 3 行找镜头');
    expect(b.lines, hasLength(1));
  });

  test('空话不播——宁可不说，也不占着一行说废话', () {
    expect(AgentBroadcast.empty.push('').lines, isEmpty);
    expect(AgentBroadcast.empty.push('   ').lines, isEmpty);
  });

  test('只有最后一条是「正在做」，前面的都是「做完了」', () {
    final b = AgentBroadcast.empty.push('正在新建任务').push('正在提取台词');
    expect(b.lines.last.done, isFalse);
    expect(b.lines.first.done, isTrue,
        reason: '打勾变灰，人一眼看出走到哪儿了');
  });

  test('收工时全部标成做完——Agent 走了就不该还有一条在转圈', () {
    final b = AgentBroadcast.empty.push('正在导出').finish();
    expect(b.lines.every((l) => l.done), isTrue);
  });

  test('清空', () {
    expect(AgentBroadcast.empty.push('a').cleared().lines, isEmpty);
  });
}
