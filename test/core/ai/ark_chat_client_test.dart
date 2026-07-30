import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/net/json_poster.dart';

void main() {
  test('chatText 组装 OpenAI 兼容请求并取回 content', () async {
    late Uri sentUrl;
    late Map<String, String> sentHeaders;
    late Map<String, dynamic> sentBody;
    final client = ArkChatClient(
      apiKey: 'test-key',
      post: (url, headers, body) async {
        sentUrl = url;
        sentHeaders = headers;
        sentBody = jsonDecode(body) as Map<String, dynamic>;
        return JsonPostResult(
            statusCode: 200,
            body: jsonEncode({
              'choices': [
                {'message': {'role': 'assistant', 'content': '答案', 'reasoning_content': '思考过程'}}
              ]
            }));
      },
    );
    final content = await client.chatText(system: '你是助手', user: '问题');
    expect(content, '答案');
    expect(sentUrl.host, 'ark.cn-beijing.volces.com');
    expect(sentHeaders['Authorization'], 'Bearer test-key');
    expect(sentBody['model'], 'doubao-seed-2-0-lite-260215');
    final messages = sentBody['messages'] as List<dynamic>;
    expect(messages.first, {'role': 'system', 'content': '你是助手'});
    expect(messages.last, {'role': 'user', 'content': '问题'});
  });

  test('chatVision 以 data URL 传图', () async {
    late Map<String, dynamic> sentBody;
    final client = ArkChatClient(
      apiKey: 'k',
      post: (_, _, body) async {
        sentBody = jsonDecode(body) as Map<String, dynamic>;
        return JsonPostResult(
            statusCode: 200,
            body: jsonEncode({
              'choices': [
                {'message': {'content': '画面描述'}}
              ]
            }));
      },
    );
    final content =
        await client.chatVision(prompt: '描述画面', jpegBytes: [1, 2, 3]);
    expect(content, '画面描述');
    final userContent =
        ((sentBody['messages'] as List).single['content'] as List);
    expect(userContent.first['type'], 'image_url');
    expect(userContent.first['image_url']['url'],
        'data:image/jpeg;base64,${base64Encode([1, 2, 3])}');
    expect(userContent.last, {'type': 'text', 'text': '描述画面'});
  });

  test('API 错误抛 AiHttpException 且带错误码', () async {
    final client = ArkChatClient(
      apiKey: 'k',
      post: (_, _, _) async => JsonPostResult(
          statusCode: 404,
          body: jsonEncode({
            'error': {'code': 'ModelNotOpen', 'message': '未开通'}
          })),
    );
    expect(
      () => client.chatText(user: 'x'),
      throwsA(isA<AiHttpException>()
          .having((e) => e.message, 'message', contains('ModelNotOpen'))),
    );
  });

  test('响应缺 choices 抛 AiHttpException', () async {
    final client = ArkChatClient(
      apiKey: 'k',
      post: (_, _, _) async =>
          const JsonPostResult(statusCode: 200, body: '{}'),
    );
    expect(() => client.chatText(user: 'x'), throwsA(isA<AiHttpException>()));
  });
}
