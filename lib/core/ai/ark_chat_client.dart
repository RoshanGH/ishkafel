import 'dart:convert';
import '../net/json_poster.dart';

/// 火山方舟 chat/completions 封装（文本 + 视觉多模态，同一模型）
///
/// 注意：所选模型为思考模型，响应含 reasoning_content——业务只取 content。
class ArkChatClient {
  static final _defaultEndpoint =
      Uri.parse('https://ark.cn-beijing.volces.com/api/v3/chat/completions');

  final String apiKey;
  final String model;
  final JsonPoster post;
  final Uri endpoint;

  ArkChatClient({
    required this.apiKey,
    this.model = 'doubao-seed-2-0-lite-260215',
    this.post = httpJsonPoster,
    Uri? endpoint,
  }) : endpoint = endpoint ?? _defaultEndpoint;

  Future<String> chatText({
    String? system,
    required String user,
    int maxTokens = 4096,
  }) =>
      _chat([
        if (system != null) {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ], maxTokens);

  Future<String> chatVision({
    required String prompt,
    required List<int> jpegBytes,
    int maxTokens = 1024,
  }) =>
      _chat([
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:image/jpeg;base64,${base64Encode(jpegBytes)}'
              },
            },
            {'type': 'text', 'text': prompt},
          ],
        },
      ], maxTokens);

  Future<String> _chat(List<Map<String, dynamic>> messages, int maxTokens) async {
    final result = await post(
      endpoint,
      {'Authorization': 'Bearer $apiKey'},
      jsonEncode({'model': model, 'messages': messages, 'max_tokens': maxTokens}),
    );
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(result.body) as Map<String, dynamic>;
    } on FormatException {
      throw AiHttpException('Ark 响应非 JSON：${result.body}',
          statusCode: result.statusCode);
    }
    final error = json['error'];
    if (result.statusCode != 200 || error != null) {
      final code = error is Map ? error['code'] : null;
      final message = error is Map ? error['message'] : result.body;
      throw AiHttpException('Ark 调用失败 [$code]：$message',
          statusCode: result.statusCode);
    }
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) {
      throw AiHttpException('Ark 响应缺少 choices：${result.body}',
          statusCode: result.statusCode);
    }
    final content = (choices.first as Map)['message']?['content'];
    if (content is! String) {
      throw AiHttpException('Ark 响应缺少 content', statusCode: result.statusCode);
    }
    return content;
  }
}
