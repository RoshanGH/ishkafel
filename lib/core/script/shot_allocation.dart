import 'script_doc.dart';

/// 行内时长分配（设计稿定稿的颗粒度规则）：
///
/// - 行时长是**根**（配音行 = 配音时长；画面行 = 手填或随素材），
///   镜头们分这块蛋糕，**总长锁死**
/// - 每镜最少 [minShotMs]，放不下就该删镜（引擎不替用户删，只拒绝）
/// - 邻镜联动：一个镜头变长，右邻（其次左邻）等量变短
/// - 变速改可用量：素材 6s 在 1.5x 下只够出 4s
///
/// 全部纯函数：入参不改、返回新列表；办不到时返回 null（由界面解释原因）。
abstract final class ShotAllocation {
  static const int minShotMs = 500;

  /// 行的时长根。配音行 = 已生成的配音时长（没配音返回 null——先配音再
  /// 分时长）；画面行 = 手填时长，没填则按素材原始时长顺次相加（随素材）
  static int? rootMsOf(ScriptLine line) {
    if (line.type == ScriptLineType.voiced) {
      return line.voiceover?.durationMs;
    }
    if (line.manualMs != null) return line.manualMs;
    if (line.shots.isEmpty) return null;
    var sum = 0;
    for (final s in line.shots) {
      if (s.durationMs == null) return null; // 时长未知就「随」不出来
      sum += (s.durationMs! / s.speed).floor();
    }
    return sum;
  }

  /// 初始均分（挑完镜头/换根之后调用）：每镜 root/n，受最小值与可用量夹逼，
  /// 余数从左往右塞给还有余量的镜头。
  ///
  /// 分不满 root（素材总可用量不够）也照样返回——缺口由 [shortfallMs]
  /// 算出来交给界面警告，不静默把片子变短。
  static List<LineShot> distribute(List<LineShot> shots, int rootMs) {
    if (shots.isEmpty) return shots;
    final n = shots.length;
    final base = rootMs ~/ n;
    final result = [
      for (final s in shots)
        s.copyWith(allocMs: base.clamp(minShotMs, s.availableMs)),
    ];
    // 把没分完的从左往右补给还有余量的
    var left = rootMs - result.fold(0, (a, s) => a + (s.allocMs ?? 0));
    for (var i = 0; i < n && left > 0; i++) {
      final s = result[i];
      final room = s.availableMs - (s.allocMs ?? 0);
      if (room <= 0) continue;
      final add = left < room ? left : room;
      result[i] = s.copyWith(allocMs: (s.allocMs ?? 0) + add);
      left -= add;
    }
    return result;
  }

  /// 混合分配：**划词镜的时长定死，自由镜均分剩下的**。
  ///
  /// 一句 8 秒的话，划了头 2 秒、尾 2 秒，中间就只剩 4 秒——不管中间放
  /// 几个镜头，加起来永远是那 4 秒。这是硬约束，不是建议值。
  ///
  /// 划词镜之间**允许留空隙**（那段没画面）：不去凑满、不悄悄把画面拉长，
  /// 缺口交给 [shortfallMs] 如实报出来。
  ///
  /// 拿不到逐字时间（还没配音、老服务端没给）时退回 [distribute]：
  /// 算不出真时长就别装作算得出。
  static List<LineShot> distributeWithWords(
    List<LineShot> shots,
    int rootMs,
    List<VoiceWord> words,
  ) {
    if (shots.isEmpty) return shots;
    final bound = <int, int>{}; // 下标 → 定死的时长
    for (var i = 0; i < shots.length; i++) {
      final s = shots[i];
      if (!s.boundToWords) continue;
      final span = wordSpanMs(words, s.startWord!, s.endWord!, totalMs: rootMs);
      if (span == null) continue; // 没有逐字时间，这一镜只能按自由镜处理
      // 素材给不了这么长时如实少给，缺口由 shortfallMs 报出来
      bound[i] = span.clamp(0, s.availableMs);
    }
    if (bound.isEmpty) return distribute(shots, rootMs);

    final boundTotal = bound.values.fold(0, (a, b) => a + b);
    final freeIndexes = [
      for (var i = 0; i < shots.length; i++)
        if (!bound.containsKey(i)) i,
    ];
    // 划词镜已经占满（甚至超过）时，自由镜分到 0——**不倒扣划词镜**：
    // 人明确说了那几个字配那个画面，软件无权改小它
    final freeTotal = (rootMs - boundTotal).clamp(0, rootMs);

    final result = [...shots];
    for (final e in bound.entries) {
      result[e.key] = shots[e.key].copyWith(allocMs: e.value);
    }
    if (freeIndexes.isNotEmpty) {
      final freeShots = [for (final i in freeIndexes) shots[i]];
      // **不能直接用 distribute**：它有最小镜头时长的下限，会把「只剩
      // 300ms 给两个自由镜」抬成「各 500ms」，加起来就超过了配音总长——
      // 而中间那段是硬约束，超出去就等于把划词镜挤变形了
      final divided = _divideExactly(freeShots, freeTotal);
      for (var k = 0; k < freeIndexes.length; k++) {
        result[freeIndexes[k]] = divided[k];
      }
    }
    return result;
  }

  /// 把 [total] 严格分给这几镜，**总和一分不多一分不少**。
  ///
  /// 与 [distribute] 的区别：这里没有最小时长下限。总量是硬约束时
  /// （划词镜之间剩下的那段）不能为了「镜头别太短」把总和撑破——
  /// 镜头短是人自己划出来的，撑破总长则会让画面和声音整体错位
  static List<LineShot> _divideExactly(List<LineShot> shots, int total) {
    if (shots.isEmpty) return shots;
    final n = shots.length;
    final base = total ~/ n;
    final result = [
      for (final s in shots) s.copyWith(allocMs: base.clamp(0, s.availableMs)),
    ];
    var left = total - result.fold(0, (a, s) => a + (s.allocMs ?? 0));
    for (var i = 0; i < n && left > 0; i++) {
      final room = result[i].availableMs - (result[i].allocMs ?? 0);
      if (room <= 0) continue;
      final add = left < room ? left : room;
      result[i] = result[i].copyWith(allocMs: (result[i].allocMs ?? 0) + add);
      left -= add;
    }
    return result;
  }

  /// 分配合计与根的差（正数 = 还缺这么多没分出去）。界面拿它出警告
  static int shortfallMs(List<LineShot> shots, int rootMs) =>
      rootMs - shots.fold(0, (a, s) => a + (s.allocMs ?? 0));

  /// 把第 [index] 镜调整为 [newAllocMs]，差额由右邻（其次左邻）吸收。
  ///
  /// 一次只动一个邻居——「我拉长这镜，右边那镜让出来」是人对联动的直觉；
  /// 一动全行会让人追不上发生了什么。动不了（邻居们都到底了）返回 null。
  static List<LineShot>? resize(
      List<LineShot> shots, int index, int newAllocMs) {
    if (index < 0 || index >= shots.length) return null;
    final target = newAllocMs.clamp(minShotMs, shots[index].availableMs);
    var delta = target - (shots[index].allocMs ?? 0);
    if (delta == 0) return shots;
    for (final j in [index + 1, index - 1]) {
      if (j < 0 || j >= shots.length) continue;
      final neighbor = shots[j];
      final neighborAlloc = neighbor.allocMs ?? 0;
      final neighborNew = (neighborAlloc - delta)
          .clamp(minShotMs, neighbor.availableMs);
      final absorbed = neighborAlloc - neighborNew;
      if (absorbed != delta) continue; // 这个邻居吃不下全部差额，换一个
      final result = [...shots];
      result[index] = shots[index].copyWith(allocMs: target);
      result[j] = neighbor.copyWith(allocMs: neighborNew);
      return result;
    }
    return null;
  }

  /// 改起点（框选不必从头）。夹在 [0, 素材长 - 本镜消耗] 内，
  /// 保证起点右移后剩下的素材仍够出这一镜
  static LineShot setTrimStart(LineShot shot, int trimStartMs) {
    final src = shot.durationMs;
    final maxStart = src == null
        ? trimStartMs
        : (src - shot.consumedSourceMs).clamp(0, src);
    return shot.copyWith(trimStartMs: trimStartMs.clamp(0, maxStart));
  }

  /// 放慢的底线：低于 0.5x 画面明显拖沓（鬼畜慢放），宁可留缺口如实警告
  static const double minFillSpeed = 0.5;

  /// 素材偏短分不满根时，把镜头**放慢**吃掉缺口（分镜可加速可放慢，
  /// 短了就慢放充满——比留一个「素材不够长」的警告有用得多）。
  ///
  /// 从最后一镜往前动：能吃下缺口就不惊动前面的镜头。只降速不升速；
  /// 降到 [minFillSpeed] 还不够就留着剩余缺口继续警告。
  /// 没缺口时原列表原样返回。
  static List<LineShot> fillBySlowdown(List<LineShot> shots, int rootMs) {
    var left = shortfallMs(shots, rootMs);
    if (left <= 0 || shots.isEmpty) return shots;
    final result = [...shots];
    for (var i = result.length - 1; i >= 0 && left > 0; i--) {
      final s = result[i];
      final src = s.durationMs;
      if (src == null) continue; // 时长未知的镜头不动
      final usable = s.localSource != null ? src : src - s.trimStartMs;
      if (usable <= 0) continue;
      final need = (s.allocMs ?? 0) + left;
      // 放慢到两位小数（界面显示 0.87x 这类干净数字），只降不升
      var speed = (usable / need * 100).floor() / 100;
      speed = speed.clamp(minFillSpeed, s.speed);
      if (speed >= s.speed) continue;
      final slowed = s.copyWith(speed: speed);
      final alloc = need < slowed.availableMs ? need : slowed.availableMs;
      result[i] = slowed.copyWith(allocMs: alloc);
      left -= alloc - (s.allocMs ?? 0);
    }
    return result;
  }

  /// 显式变速。**变速清框重选**（设计稿）：起点归零；可用量随之变化，
  /// 分配超出新可用量时压到可用量——差额由调用方走 [resize] 联动，
  /// 联动不了就留着缺口走警告
  static LineShot setSpeed(LineShot shot, double speed) {
    final next = shot.copyWith(speed: speed, trimStartMs: 0);
    final alloc = next.allocMs;
    if (alloc != null && alloc > next.availableMs) {
      return next.copyWith(allocMs: next.availableMs.clamp(minShotMs, 1 << 30));
    }
    return next;
  }
}

/// 字区间 `[start, end)` 读出来有多长（毫秒）。
///
/// 划词建镜的地基：人选中「如果你觉得有点贵」，这几个字读多久，那一镜
/// 就占多久。**现算不存**——换音色、重配音之后朗读长短全变，切点不变、
/// 时长自动跟上。
///
/// **停顿归前一镜**。算的是「下一个字开口 − 本段第一个字开口」，
/// 而不是「本段最后一个字收音 − 第一个字开口」：
///
/// 真机数据（滴露那条 43 字的长句）——「贵」收音在 1440ms，下一个字
/// 「那」开口在 1560ms，中间 120ms 是逗号的气口。按收音切，画面会在
/// 停顿刚开始时就切走，急了小半拍；按下一个字开口切，气口留给前一镜，
/// 画面正好在下一句出声那一刻换。全句 5 个标点处的气口是 80~280ms，
/// 都在肉眼能看出来的量级。
///
/// [totalMs] 是这句配音的总长，**最后一段用它收尾**：句尾的余韵
/// （TTS 稳定在 200~350ms 的尾部静音）也该归最后一镜，否则整句的镜头
/// 加起来会比配音短一截。
///
/// 没有逐字时间就返回 null：算不出来就说算不出来，不猜一个假时长顶上。
int? wordSpanMs(List<VoiceWord> words, int start, int end, {int? totalMs}) {
  if (words.isEmpty) return null;
  final a = start.clamp(0, words.length);
  final b = end.clamp(0, words.length);
  if (b <= a) return 0;
  final from = words[a].startMs;
  // 后面还有字：切在下一个字开口处，气口留给这一镜
  if (b < words.length) return words[b].startMs - from;
  // 已经是最后一段：收到配音结尾，余韵归它
  final tail = totalMs != null && totalMs > words[b - 1].endMs
      ? totalMs
      : words[b - 1].endMs;
  return tail - from;
}

/// 划词镜之间有没有重叠、有没有排错序。返回人话原因；null = 没问题。
///
/// 规矩是**不做兼容**：重叠了就让人先删掉那一镜再划，不去猜他想要什么、
/// 也不自动合并。自动合并出来的结构人看不懂，删了重划反而更快
String? wordBoundConflict(List<LineShot> shots) {
  final bound = [
    for (final s in shots)
      if (s.boundToWords) s,
  ];
  for (var i = 1; i < bound.length; i++) {
    final prev = bound[i - 1];
    final cur = bound[i];
    if (cur.startWord! < prev.endWord!) {
      return '第 ${i + 1} 个划词镜头和前一个重叠了。'
          '先删掉其中一个再划——重叠的部分没法既属于这一镜又属于那一镜';
    }
  }
  return null;
}

/// 重排一行的镜头时长——**全软件唯一入口**。
///
/// 真机 bug：人先划词建了两个镜（时长按朗读长短算好），再用「找镜头」加
/// 两个镜，那条路径调的是老的均分函数，把整行重新平摊，4 个镜头全变成
/// 8880÷4=2220ms。划的词等于白划，而且不报错、不提示。
///
/// 根因是「同一个东西两处算」：9 个调用点各自决定调 [ShotAllocation.
/// distribute] 还是 [ShotAllocation.distributeWithWords]，漏一个就悄悄错。
/// 今天已经因为同一个毛病出过静音、配音过期两个 bug——所以这里收口：
/// **调用方不需要知道有没有划词镜**，交给它自己判断。
List<LineShot> reallocShots(ScriptLine line, List<LineShot> shots) {
  final root = ShotAllocation.rootMsOf(line.withShots(shots));
  if (root == null) return shots;
  final words = line.voiceover?.words ?? const <VoiceWord>[];
  return ShotAllocation.distributeWithWords(shots, root, words);
}
