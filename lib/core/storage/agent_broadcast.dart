/// 播报里的一条**是哪一类**。
///
/// 三种东西混在同一种样式里，人只会当成一串流水账划过去：
/// - [step] 进度：「正在给 U2S4 挑素材」——它走到哪儿了
/// - [judgement] 判断：「标签命中 5318 条太宽，改用画面描述再搜一轮」
///   ——它为什么改主意了。**这一类最值钱**：人肯把花钱的活交给静默模式，
///   靠的正是「我看懂过它是怎么想的」
/// - [warning] 发现问题：「这条素材画面上烧着别家的字」——人可能要当场喊停
enum BroadcastKind { step, judgement, warning }

/// 播报流里的一条
class BroadcastLine {
  final String text;

  /// 这一条是进度、是判断，还是发现了问题
  final BroadcastKind kind;

  /// 做完了没有。**只有最后一条是「正在做」**——打勾变灰，
  /// 人一眼看出走到哪儿了
  final bool done;

  const BroadcastLine({
    required this.text,
    this.done = false,
    this.kind = BroadcastKind.step,
  });
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

  AgentBroadcast push(String text, {BroadcastKind kind = BroadcastKind.step}) {
    final t = text.trim();
    // 空话不播：宁可不说，也不占着一行说废话
    if (t.isEmpty) return this;
    // 同一句连着来不重复排——重试、轮询会把真正的动作淹掉
    if (lines.isNotEmpty && lines.last.text == t) return this;
    final next = [
      // 前面的都标成做完，各自是哪一类不变
      for (final l in lines)
        BroadcastLine(text: l.text, done: true, kind: l.kind),
      BroadcastLine(text: t, kind: kind),
    ];
    return AgentBroadcast(_trimmed(next));
  }

  /// 超出 [maxLines] 时砍最旧的，但**发现的问题留着**。
  ///
  /// 人走开一会儿回来，最该看见的就是那条警告；被后面几句流水账挤掉的话
  /// 等于没报过。判断类不给这个待遇——它出现得远比警告频繁，都留着的话
  /// 播报栏里就全是它、看不到现在在干嘛了。
  static List<BroadcastLine> _trimmed(List<BroadcastLine> lines) {
    if (lines.length <= maxLines) return lines;
    final keep = <BroadcastLine>[];
    // 从新往旧收：最新的先占位，然后是没被收进来的警告
    for (var i = lines.length - 1; i >= 0 && keep.length < maxLines; i--) {
      final isNewest = i == lines.length - 1;
      final recent = lines.length - 1 - i < maxLines - _warningSlots;
      if (isNewest || recent || lines[i].kind == BroadcastKind.warning) {
        keep.add(lines[i]);
      }
    }
    return keep.reversed.toList();
  }

  /// 最多为「发现的问题」留几行。留太多的话，一条素材接一条素材地报问题
  /// 会把「现在在干嘛」整个挤出去
  static const int _warningSlots = 2;

  /// 收工：全部标成做完——Agent 走了就不该还有一条在转圈
  AgentBroadcast finish() => AgentBroadcast([
        for (final l in lines)
          BroadcastLine(text: l.text, done: true, kind: l.kind),
      ]);

  AgentBroadcast cleared() => empty;
}
