/// 播报流里的一条
class BroadcastLine {
  final String text;

  /// 做完了没有。**只有最后一条是「正在做」**——打勾变灰，
  /// 人一眼看出走到哪儿了
  final bool done;

  const BroadcastLine({required this.text, this.done = false});
}

/// Agent 干活时的**播报流**：它现在在做什么，刚才做了什么。
///
/// 用户的原话：「下面有一个播报——Agent 正在新建任务、正在给第三行找视频、
/// 正在给第 3~15 行配背景音乐……只保留最近 5 条，最起码 0.5 秒过一个，
/// 让我能看清字。」
///
/// 为什么不是原来那条横幅：横幅只显示当前一条，下一步一到就被覆盖，
/// 切太快等于没有。播报流解决的是**「我刚走神了，它这几步做了什么」**——
/// 而人要敢把活交出去，靠的正是这种「全程看得见」积累起来的信任。
class AgentBroadcast {
  final List<BroadcastLine> lines;

  const AgentBroadcast(this.lines);

  static const empty = AgentBroadcast([]);

  /// 最多留几条。再多就成了刷屏，人根本读不过来
  static const maxLines = 5;

  AgentBroadcast push(String text) {
    final t = text.trim();
    // 空话不播：宁可不说，也不占着一行说废话
    if (t.isEmpty) return this;
    // 同一句连着来不重复排——重试、轮询会把真正的动作淹掉
    if (lines.isNotEmpty && lines.last.text == t) return this;
    final next = [
      // 前面的都标成做完
      for (final l in lines) BroadcastLine(text: l.text, done: true),
      BroadcastLine(text: t),
    ];
    return AgentBroadcast(
        next.length <= maxLines ? next : next.sublist(next.length - maxLines));
  }

  /// 收工：全部标成做完——Agent 走了就不该还有一条在转圈
  AgentBroadcast finish() => AgentBroadcast([
        for (final l in lines) BroadcastLine(text: l.text, done: true),
      ]);

  AgentBroadcast cleared() => empty;
}
