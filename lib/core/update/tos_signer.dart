import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 火山 TOS 的**预签名下载链接**（SigV4，query 形式）。
///
/// 为什么要签名：产物里 `--dart-define` 注入的 AI 凭据是**明文躺在二进制里**
/// 的（`strings` 一抠就有）。包一旦公开读，谁拿到链接都能提出方舟 key 去烧钱。
/// 私有存放 + 临时链接把泄露面从「AI 凭据」降到「安装包本身」。
///
/// 只做**读**这一件事：app 里带的那对凭据只该有 GetObject 权限。
class TosSigner {
  final String accessKey;
  final String secretKey;
  final String region;
  final String bucket;

  /// 服务域名，如 `tos-cn-beijing.volces.com`
  final String endpoint;

  const TosSigner({
    required this.accessKey,
    required this.secretKey,
    required this.region,
    required this.bucket,
    required this.endpoint,
  });

  static const _service = 'tos';
  static const _algorithm = 'TOS4-HMAC-SHA256';

  /// 给 [objectKey] 换一条有效期 [ttl] 的下载链接。
  ///
  /// [now] 只给测试用——签名里带时间戳，不注入就没法断言出稳定结果
  String presignGet(
    String objectKey, {
    Duration ttl = const Duration(minutes: 30),
    DateTime? now,
  }) {
    final at = (now ?? DateTime.now().toUtc()).toUtc();
    final stamp = _iso8601(at);
    final day = stamp.substring(0, 8);
    final scope = '$day/$region/$_service/request';
    final host = '$bucket.$endpoint';
    final canonicalUri =
        '/${objectKey.split('/').map(_uriEncode).join('/')}';

    final query = <String, String>{
      'X-Tos-Algorithm': _algorithm,
      'X-Tos-Credential': '$accessKey/$scope',
      'X-Tos-Date': stamp,
      'X-Tos-Expires': '${ttl.inSeconds}',
      'X-Tos-SignedHeaders': 'host',
    };
    final canonicalQuery = (query.keys.toList()..sort())
        .map((k) => '${_uriEncode(k)}=${_uriEncode(query[k]!)}')
        .join('&');

    final canonicalRequest = [
      'GET',
      canonicalUri,
      canonicalQuery,
      'host:$host\n',
      'host',
      'UNSIGNED-PAYLOAD',
    ].join('\n');

    final stringToSign = [
      _algorithm,
      stamp,
      scope,
      _hex(sha256.convert(utf8.encode(canonicalRequest)).bytes),
    ].join('\n');

    var key = <int>[...utf8.encode(secretKey)];
    for (final part in [day, region, _service, 'request']) {
      key = Hmac(sha256, key).convert(utf8.encode(part)).bytes;
    }
    final signature =
        _hex(Hmac(sha256, key).convert(utf8.encode(stringToSign)).bytes);

    return 'https://$host$canonicalUri?$canonicalQuery'
        '&X-Tos-Signature=$signature';
  }

  /// `20260902T083000Z`
  static String _iso8601(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${at.year}${two(at.month)}${two(at.day)}'
        'T${two(at.hour)}${two(at.minute)}${two(at.second)}Z';
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// RFC 3986。`/` 由调用方按段拼，所以这里一律转义
  static String _uriEncode(String raw) {
    const safe =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~';
    final out = StringBuffer();
    for (final byte in utf8.encode(raw)) {
      final ch = String.fromCharCode(byte);
      if (safe.contains(ch)) {
        out.write(ch);
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return '$out';
  }
}
