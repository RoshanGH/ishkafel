import 'package:collection/collection.dart';
import 'segmentation_builder.dart';

/// ASR 给的置信度：**恰好为 0 就是「这个字段没给」。**
///
/// 火山 ASR 的响应里每个词都带 `confidence`，值恒为 0——四条真实任务
/// 1703 个词，一个例外都没有。而「百分百听错」这种断言没有哪个 ASR 会下，
/// 所以 0 只能理解成「没这个字段」。
///
/// 在解析这一层就置 null，「没给」和「给了 0」才分得开：报告那层的
/// `if (confidence != null)` 只挡得住字段缺失，挡不住「字段在、但恒为 0」，
/// Agent 会看到一列 0.0，而手册曾教它拿低置信度认错别字——那是一条死路。
/// 盘上已有的任务也走这里（[AsrWord.fromJson]），不是只管新转写的。
double? asrConfidenceOf(Object? raw) =>
    raw is num && raw.isFinite && raw != 0 ? raw.toDouble() : null;

/// ASR 识别出的一个字/词（字级时间戳，精度红线：ASR 返回什么精度就保留什么精度）
class AsrWord {
  final int startMs;
  final int endMs;
  final String text;
  final double? confidence;

  const AsrWord({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.confidence,
  });

  Map<String, dynamic> toJson() => {
        'startMs': startMs,
        'endMs': endMs,
        'text': text,
        if (confidence != null) 'confidence': confidence,
      };

  factory AsrWord.fromJson(Map<String, dynamic> json) => AsrWord(
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        text: json['text'] as String,
        confidence: asrConfidenceOf(json['confidence']),
      );

  @override
  bool operator ==(Object other) =>
      other is AsrWord &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.text == text &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(startMs, endMs, text, confidence);
}

/// ASR 识别出的一句台词（带时间戳，粗精度；可选携带字级时间戳）
class AsrSentence {
  final int startMs;
  final int endMs;
  final String text;
  final List<AsrWord> words;

  const AsrSentence({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.words = const [],
  });

  Map<String, dynamic> toJson() => {
        'startMs': startMs,
        'endMs': endMs,
        'text': text,
        'words': words.map((w) => w.toJson()).toList(),
      };

  factory AsrSentence.fromJson(Map<String, dynamic> json) => AsrSentence(
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        text: json['text'] as String,
        words: (json['words'] as List<dynamic>?)
                ?.map((e) => AsrWord.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  static const _listEq = ListEquality<Object>();

  @override
  bool operator ==(Object other) =>
      other is AsrSentence &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.text == text &&
      _listEq.equals(other.words, words);

  @override
  int get hashCode =>
      Object.hash(startMs, endMs, text, Object.hashAll(words));
}

/// 语音识别提供方（M2b 提供火山方舟真实现）
abstract class AsrProvider {
  Future<List<AsrSentence>> transcribe(String pcmPath);
}

/// 语义切分提供方：把 ASR 句子按语义分组为单元草稿（M2b 提供 LLM 真实现）
abstract class SemanticSplitter {
  Future<List<UnitDraft>> split(List<AsrSentence> sentences);
}
