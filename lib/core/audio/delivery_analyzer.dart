import 'dart:convert';

import '../ai/ark_chat_client.dart';
import '../log/app_log.dart';
import 'prosody_profile.dart';

/// 一段原声「是怎么念的」，以及据此写给合成模型的语音指令
class DeliveryAnalysis {
  /// 模型听完原声给出的描述（人看的，也是过程量）
  final String description;

  /// 直接塞给 TTS 的 `context_texts`。形如
  /// 「你可以用急促、有压迫感的语气快速催促观众吗？重音落在价格上。」
  final String instruction;

  /// 客观测量到的语速/停顿/重音，作为佐证一并留痕
  final ProsodyProfile? prosody;

  /// 模型原样回复，解析出错时靠它定位
  final String? rawReply;

  const DeliveryAnalysis({
    required this.description,
    required this.instruction,
    this.prosody,
    this.rawReply,
  });

  Map<String, dynamic> toJson() => {
        'description': description,
        'instruction': instruction,
        'prosody': prosody?.describe(),
        'rawReply': rawReply,
      };

  static DeliveryAnalysis? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final instruction = raw['instruction'];
    if (instruction is! String || instruction.trim().isEmpty) return null;
    return DeliveryAnalysis(
      description:
          raw['description'] is String ? raw['description'] as String : '',
      instruction: instruction,
      rawReply: raw['rawReply'] is String ? raw['rawReply'] as String : null,
    );
  }
}

/// 「这段原声是怎么念的」——听出来，再写成一句能喂给合成模型的指令。
///
/// 做成接口是因为这一层最可能被换掉：目前用能听音频的对话模型直接听原声
/// （本账号下 `doubao-seed-2-0-*-260428` 支持 `input_audio`，同批次的 260215
/// 反而不支持）；将来若有更合适的模型或专门的情感识别服务，换实现即可，
/// 上下游不动。
abstract class DeliveryAnalyzer {
  Future<DeliveryAnalysis> analyze({
    required List<int> audioWav,
    required String transcript,
    ProsodyProfile? prosody,
  });
}

/// 让多模态模型直接听原声。
///
/// 为什么还要带上 [ProsodyProfile]：模型光听容易顺着台词内容脑补（「促销文案
/// 嘛，那肯定是急切的」）。把测出来的语速、停顿、被拖长的字一并给它，等于
/// 递上客观证据，让它的判断落在这段录音本身上。实测两条路径互相印证——模型
/// 听出「重音落在『再不买』和『六十九点九』」，而字级时间戳测出被拖长的正是
/// 「69.9」（800ms，平均字长的三倍多）。
class ArkDeliveryAnalyzer implements DeliveryAnalyzer {
  final ArkChatClient chat;

  /// 支持音频输入的模型。注意不是所有 seed-2.0 都行：260428 那批支持，
  /// 260215 那批报 `audio input is not supported by this model`。
  final String model;

  const ArkDeliveryAnalyzer({
    required this.chat,
    this.model = 'doubao-seed-2-0-lite-260428',
  });

  @override
  Future<DeliveryAnalysis> analyze({
    required List<int> audioWav,
    required String transcript,
    ProsodyProfile? prosody,
  }) async {
    final content = await chat.chatAudio(
      model: model,
      prompt: _prompt(transcript, prosody),
      audioWav: audioWav,
    );
    final json = _tryJson(content);
    final description = _string(json?['description']) ?? '';
    final instruction = _string(json?['instruction']);
    if (instruction == null || instruction.isEmpty) {
      // 解析不出指令时不编一个：一句瞎猜的语音指令会让整段配音跑偏，
      // 而「没有指令」只是退回模型默认的念法，损失小得多。
      AppLog.warn('演绎分析没有拿到可用的语音指令，将不带指令合成');
      return DeliveryAnalysis(
        description: description,
        instruction: '',
        prosody: prosody,
        rawReply: content,
      );
    }
    return DeliveryAnalysis(
      description: description,
      instruction: instruction,
      prosody: prosody,
      rawReply: content,
    );
  }

  String _prompt(String transcript, ProsodyProfile? prosody) => '''
这是一段短视频带货口播的原声。台词是：$transcript
${prosody != null && prosody.hasSignal ? '客观测量：${prosody.describe()}' : ''}

请听这段录音，判断说话人是**怎么念**的——语气、情绪、语速、重音落在哪里。
注意只描述念法，不要复述台词内容。

然后写一句**对配音演员说的话**，让另一个人用不同的音色念出同样的感觉。
这句话会直接交给语音合成模型，要具体、可执行，控制在 40 字以内。

只输出 JSON：
{"description":"这段是怎么念的","instruction":"你可以用……的语气说吗？"}''';

  static Map<String, dynamic>? _tryJson(String content) {
    var text = content.trim();
    final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(text);
    if (fence != null) text = fence.group(1)!;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static String? _string(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }
}
