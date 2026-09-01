import 'dart:io';

import 'package:path/path.dart' as p;

import 'script_doc.dart';

/// 人自己录的配音，在音色这一栏里叫什么。
///
/// **必须有一个自己的身份**：判定「配音新不新」是拿行的有效音色和配音记录
/// 里的音色比（见 [ScriptLine.voiceStateAgainst]）。人工配音要是没有身份，
/// 就会被算成「本片基调那个音色」，一比对不上 → 判成过期 → 下一次
/// `script voice` 直接拿 TTS 把人辛苦录的盖掉。
const String humanVoiceId = 'human';

/// 这一行的配音是人自己录的吗
bool isHumanVoice(ScriptLine line) =>
    line.voiceover?.voiceId == humanVoiceId;

/// 把一段**人自己录的音频**装进某一行。
///
/// 这条线的时间根是配音时长，所以人录了什么，这一行就有多长——镜头分配、
/// 断句、字幕打轴全部从这里重新长出来。
///
/// **音频里说的和脚本里写的不一样时，以音频为准。** 人已经念出来了，
/// 那就是事实；改脚本去将就音频，而不是反过来要求人重录。
/// 台词一改，按字划出来的分镜就不成立了（字的位置全变了），调用方要说出来。
ScriptDoc applyUploadedVoice({
  required ScriptDoc doc,
  required int lineIndex,
  required String audioPath,
  required int durationMs,
  required List<VoiceWord> words,

  /// ASR 听出来的文字。空的话保留原台词（音频里可能一句话都没有，
  /// 那种情况调用方该先拦下来）
  required String heardText,
}) {
  if (lineIndex < 0 || lineIndex >= doc.lines.length) {
    throw RangeError('没有第 ${lineIndex + 1} 行');
  }
  final line = doc.lines[lineIndex];
  final text = heardText.trim().isEmpty ? line.text.trim() : heardText.trim();
  var next = doc;
  if (text != line.text.trim()) {
    next = next.updateText(lineIndex, text);
  }
  // **音色和语速都要跟着落到行上**：只写进配音记录、不写到行上的话，
  // 行的「有效音色」还是全片基调，判定立刻变成过期
  next = next.setVoiceId(lineIndex, humanVoiceId);
  next = next.setSpeechRate(lineIndex, 0);
  return next.setVoiceoverById(
    next.lines[lineIndex].id,
    LineVoiceover(
      audioPath: audioPath,
      durationMs: durationMs,
      sourceText: text,
      voiceId: humanVoiceId,
      speechRate: 0,
      words: words,
    ),
  );
}


/// 把人给的音频**收进任务名下**。
///
/// 他给的那个文件随时可能被移走、改名、删掉，而它现在是这一行的时间根
/// ——留在外面等于把成片的地基放在别人家里。删任务时随 voices 目录一起清走。
Future<File> keepUploadedVoice({
  required File source,
  required Directory dataDir,
  required String taskId,
  required String lineId,
}) async {
  final dir = Directory(p.join(dataDir.path, 'voices', taskId));
  dir.createSync(recursive: true);
  final ext = p.extension(source.path).toLowerCase();
  return source.copy(p.join(dir.path, '${lineId}_mine$ext'));
}
