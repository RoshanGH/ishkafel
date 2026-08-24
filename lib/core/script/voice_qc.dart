import 'script_doc.dart';

/// 合成配音的质检：**念出来的和写的对不对得上**。
///
/// 大模型 TTS 会抽风——解码陷进循环，后半句两三个词一直重复到结尾；
/// 也会念到一半就断。这类音频听着就是「卡住了」，绝不能悄悄进成片
/// （真机反馈：第 15 句后半段一直重复）。
///
/// 判据用的是**现成的证据**：为了拿词级时间戳，合成完本来就要用 ASR
/// 把音频转写一遍。转写文本与原文一比，抽风就藏不住了。
///
/// 判得**宽**是刻意的：ASR 会把「10瓶」听成「十瓶」、「厨垫」听成
/// 「橱垫」，这类同音/异写差异必须放过——误杀一次就是白花一次钱、
/// 白等一次合成。只抓那些一眼就不对的：字数暴涨、明显截断、语速离谱。

/// 一句配音的缺陷描述（面向用户的中文）；null = 没发现问题
String? voiceDefect({
  required String source,
  required List<VoiceWord> heard,
  required int durationMs,
}) {
  // 没有转写结果就没有证据——不下结论
  if (heard.isEmpty) return null;
  final want = _core(source);
  final got = _core(heard.map((w) => w.text).join());
  if (want.isEmpty || got.isEmpty) return null;

  // 一、念多了：正常的同音/异写差异撑不出这么多字
  if (got.length > want.length * 1.2 + 4) {
    return '这一句念重复了（比台词多出 ${got.length - want.length} 个字）';
  }
  // 二、尾部卡在同一个短语上反复念——字数没暴涨也可能发生（句子长）
  final loop = _tailLoop(got);
  if (loop != null && !_repeatsInSource(want, loop)) {
    return '这一句结尾卡住了，反复在念「$loop」';
  }
  // 三、念到一半断了
  if (got.length < want.length * 0.6) {
    return '这一句没念完（只念了 ${got.length}/${want.length} 个字）';
  }
  // 四、语速离谱：多半是把重复的字塞进了同一段时间
  final rate = durationMs > 0 ? got.length / (durationMs / 1000) : 0;
  if (rate > 9.5) {
    return '这一句语速异常（每秒 ${rate.toStringAsFixed(1)} 个字），多半是念岔了';
  }
  return null;
}

/// 参与比对的「核心字」：标点、空白都不算数
String _core(String text) => text.replaceAll(_ignorable, '');

final _ignorable =
    RegExp(r'[\s，。？！；：、…,.?!;:~～·"' "'" r'（）()《》<>【】\[\]—-]');

/// 结尾是不是卡在同一个短语上反复念。返回那个短语；没有则 null。
///
/// 找法：从结尾往前取 2~6 个字当候选，看它是不是连着重复了三遍以上。
/// 三遍是刻意的——「看看啊看看啊」这种台词本身的叠词只有两遍，不该被抓
String? _tailLoop(String text) {
  for (var n = 2; n <= 6; n++) {
    if (text.length < n * 3) break;
    final unit = text.substring(text.length - n);
    var times = 0;
    var end = text.length;
    while (end >= n && text.substring(end - n, end) == unit) {
      times++;
      end -= n;
    }
    if (times >= 3) return unit;
  }
  return null;
}

/// 台词本身就在重复这个短语（比如「看看啊，看看啊，看看啊」），
/// 那念三遍是对的，不算缺陷
bool _repeatsInSource(String source, String unit) {
  var count = 0;
  var from = 0;
  while (true) {
    final at = source.indexOf(unit, from);
    if (at < 0) break;
    count++;
    from = at + unit.length;
  }
  return count >= 3;
}
