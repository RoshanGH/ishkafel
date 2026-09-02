import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/update/tos_signer.dart';

/// 上传这条路**要真的发一次请求**才算验过。
///
/// 刚在验签那儿栽过一次：`codesign` 没有 `-q`，而单元测试注入的是假 runner，
/// 我让它返回什么就是什么，于是「任何包都验不过」这么大的问题一路绿灯。
/// 发布路径同理——用一个本地服务器收一次，看清方法、路径、签名、正文。
void main() {
  const signer = TosSigner(
    accessKey: 'AKTEST',
    secretKey: 'SKTEST',
    region: 'cn-beijing',
    bucket: 'ishkafel',
    endpoint: 'tos-cn-beijing.volces.com',
  );

  test('预签名 PUT 真的发得出去，方法/路径/正文都对', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    HttpRequest? seen;
    List<int> body = const [];
    server.listen((req) async {
      seen = req;
      body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      req.response.statusCode = 200;
      await req.response.close();
    });

    // 拿真签名换出来的 URL，只把 host 换成本地服务器——签名要素原样保留
    final signed = Uri.parse(signer.presignPut('releases/x.zip'));
    final local = signed.replace(
        scheme: 'http', host: '127.0.0.1', port: server.port);

    final client = HttpClient();
    final req = await client.putUrl(local);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/zip');
    final payload = utf8.encode('假装这是个包');
    req.headers.set(HttpHeaders.contentLengthHeader, '${payload.length}');
    req.add(payload);
    final res = await req.close();
    await res.drain<void>();
    client.close();
    await server.close();

    expect(res.statusCode, 200);
    expect(seen!.method, 'PUT', reason: '发布必须是 PUT，签名也是按 PUT 算的');
    expect(seen!.uri.path, '/releases/x.zip');
    expect(seen!.uri.queryParameters['X-Tos-Signature'], isNotEmpty);
    expect(seen!.uri.queryParameters['X-Tos-Algorithm'], 'TOS4-HMAC-SHA256');
    expect(utf8.decode(body), '假装这是个包', reason: '正文要原样送到，不能被截断');
  });

  test('GET 和 PUT 签出来的签名不一样——方法进了签名', () {
    final at = DateTime.utc(2026, 9, 2, 8, 30);
    final get = Uri.parse(signer.presignGet('a.zip', now: at))
        .queryParameters['X-Tos-Signature'];
    final put = Uri.parse(signer.presignPut('a.zip', now: at))
        .queryParameters['X-Tos-Signature'];
    expect(get, isNot(put),
        reason: '方法没进签名的话，只读凭据签出来的 GET 链接改成 PUT 就能上传');
  });
}
