import 'segmentation_builder.dart';

/// ASR 识别出的一句台词（带时间戳，粗精度）
class AsrSentence {
  final int startMs;
  final int endMs;
  final String text;

  const AsrSentence({
    required this.startMs,
    required this.endMs,
    required this.text,
  });
}

/// 语音识别提供方（M2b 提供火山方舟真实现）
abstract class AsrProvider {
  Future<List<AsrSentence>> transcribe(String pcmPath);
}

/// 语义切分提供方：把 ASR 句子按语义分组为单元草稿（M2b 提供 LLM 真实现）
abstract class SemanticSplitter {
  Future<List<UnitDraft>> split(List<AsrSentence> sentences);
}
