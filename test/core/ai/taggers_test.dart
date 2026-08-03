import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/ai/tag_dimension.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/net/json_poster.dart';

ArkChatClient fakeChat(String reply, {void Function(String body)? onBody}) =>
    ArkChatClient(
      apiKey: 'k',
      post: (_, _, body) async {
        onBody?.call(body);
        return JsonPostResult(
            statusCode: 200,
            body: jsonEncode({
              'choices': [
                {'message': {'content': reply}}
              ]
            }));
      },
    );

void main() {
  // 「提交台词与词表」「词表为空不调用」等用例随扁平词表一起搬到了
  // taggers_dimension_test.dart（按维度问、按维度收）。这里只留 vision
  // 通道的传输形态——那是这一层独有的、跟维度无关的契约。
  test('ShotTagger 走 vision 通道，帧以 base64 传出去', () async {
    late String sentBody;
    final tagger = ShotTagger(
        chat: fakeChat('{"画面类型":["产品特写"]}', onBody: (b) => sentBody = b));

    final r = await tagger.understand(frames: [
      [9, 9, 9]
    ], dimensions: const [
      TagDimension(
          name: '画面类型', vocabulary: ['产品特写', '人物口播'], prompt: null),
    ]);

    expect(r.tags, ['产品特写']);
    expect(sentBody, contains('image_url'));
    expect(sentBody, contains(base64Encode([9, 9, 9])));
  });
}
