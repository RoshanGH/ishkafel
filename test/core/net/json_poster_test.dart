import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/net/json_poster.dart';

void main() {
  test('JsonPostResult 持有状态码/响应体/头', () {
    const r = JsonPostResult(statusCode: 200, body: '{"ok":true}', headers: {'x-a': '1'});
    expect(r.statusCode, 200);
    expect(r.headers['x-a'], '1');
  });

  test('httpJsonPoster 对本地服务器完成 POST 往返', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      req.response.statusCode = 200;
      req.response.headers.set('x-echo-method', req.method);
      req.response.write(jsonEncode({
        'received': jsonDecode(body),
        'auth': req.headers.value('authorization'),
      }));
      await req.response.close();
    });
    final result = await httpJsonPoster(
      Uri.parse('http://127.0.0.1:${server.port}/api'),
      {'Authorization': 'Bearer test-token'},
      jsonEncode({'hello': '世界'}),
    );
    expect(result.statusCode, 200);
    expect(result.headers['x-echo-method'], 'POST');
    final json = jsonDecode(result.body) as Map<String, dynamic>;
    expect(json['received'], {'hello': '世界'});
    expect(json['auth'], 'Bearer test-token');
  });

  test('AiHttpException 携带状态码', () {
    const e = AiHttpException('boom', statusCode: 429);
    expect(e.statusCode, 429);
    expect(e.toString(), contains('boom'));
  });
}
