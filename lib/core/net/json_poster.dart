import 'dart:convert';
import 'dart:io';

/// HTTP JSON POST 的结果（不可变）
class JsonPostResult {
  final int statusCode;
  final String body;
  final Map<String, String> headers;

  const JsonPostResult({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });
}

/// HTTP POST 抽象（对标 ProcessRunner：生产用 httpJsonPoster，测试注入假实现）
typedef JsonPoster = Future<JsonPostResult> Function(
    Uri url, Map<String, String> headers, String body);

/// AI/云端 HTTP 调用失败
class AiHttpException implements Exception {
  final String message;
  final int? statusCode;
  const AiHttpException(this.message, {this.statusCode});
  @override
  String toString() => 'AiHttpException($statusCode): $message';
}

/// 默认实现：dart:io HttpClient，120 秒超时
Future<JsonPostResult> httpJsonPoster(
    Uri url, Map<String, String> headers, String body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.postUrl(url);
    request.headers.contentType = ContentType.json;
    headers.forEach(request.headers.set);
    request.write(body);
    final response =
        await request.close().timeout(const Duration(seconds: 120));
    final responseBody = await utf8.decoder.bind(response).join();
    final responseHeaders = <String, String>{};
    response.headers.forEach((k, v) => responseHeaders[k] = v.join(','));
    return JsonPostResult(
      statusCode: response.statusCode,
      body: responseBody,
      headers: responseHeaders,
    );
  } finally {
    client.close();
  }
}
