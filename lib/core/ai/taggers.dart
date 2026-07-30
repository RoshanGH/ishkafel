import 'dart:convert';
import 'ark_chat_client.dart';

/// 解析打标输出并按受控词表过滤（两个 Tagger 共用）
List<String> parseVocabTags(String content, List<String> vocabulary) {
  var text = content.trim();
  final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$');
  final m = fence.firstMatch(text);
  if (m != null) text = m.group(1)!;
  try {
    final json = jsonDecode(text) as Map<String, dynamic>;
    final tags = (json['tags'] as List<dynamic>).cast<String>();
    return List.unmodifiable(tags.where(vocabulary.contains));
  } catch (_) {
    return const [];
  }
}

String _vocabPrompt(List<String> vocabulary) => '''
候选标签（受控词表，只能从中选择，禁止自造）：${jsonEncode(vocabulary)}
从候选中选出最贴切的 0-3 个标签。只输出 JSON：{"tags":["标签名"]}''';

/// 台词语义单元打标（文本）
class UnitTagger {
  final ArkChatClient chat;
  UnitTagger({required this.chat});

  Future<List<String>> tag({
    required String transcript,
    required List<String> vocabulary,
  }) async {
    if (vocabulary.isEmpty) return const [];
    final content = await chat.chatText(
      system: '你是短视频广告素材打标员。${_vocabPrompt(vocabulary)}',
      user: '台词：$transcript',
      maxTokens: 256,
    );
    return parseVocabTags(content, vocabulary);
  }
}

/// 视觉镜头打标（代表帧走 vision 通道）
class ShotTagger {
  final ArkChatClient chat;
  ShotTagger({required this.chat});

  Future<List<String>> tag({
    required List<int> frameJpeg,
    required List<String> vocabulary,
  }) async {
    if (vocabulary.isEmpty) return const [];
    final content = await chat.chatVision(
      prompt: '这是短视频广告的一个镜头画面。${_vocabPrompt(vocabulary)}',
      jpegBytes: frameJpeg,
      maxTokens: 256,
    );
    return parseVocabTags(content, vocabulary);
  }
}
