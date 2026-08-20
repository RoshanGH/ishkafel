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
