import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/update/tos_signer.dart';

/// 预签名下载链接：**包必须私有存放**。
///
/// 产物里 `--dart-define` 注入的 AI 凭据是明文躺在二进制里的（`strings`
/// 一抠就有）。包一旦公开读，谁拿到链接都能提出方舟 key 去烧钱——所以
/// 存私有 bucket，由 app 拿只读凭据现换一条有效期很短的链接。
void main() {
  const signer = TosSigner(
    accessKey: 'AKTEST',
    secretKey: 'SKTEST',
    region: 'cn-beijing',
    bucket: 'ishkafel',
    endpoint: 'tos-cn-beijing.volces.com',
  );
  final at = DateTime.utc(2026, 9, 2, 8, 30, 0);

  test('链接指向这个 bucket 的这个对象', () {
    final url = signer.presignGet('releases/ishkafel-0.1.172.zip', now: at);
    expect(url, startsWith('https://ishkafel.tos-cn-beijing.volces.com/'));
    expect(url, contains('releases/ishkafel-0.1.172.zip'));
  });

  test('签名要素齐全，缺一条服务端就会拒', () {
    final url = signer.presignGet('a.zip', now: at);
    for (final part in [
      'X-Tos-Algorithm=TOS4-HMAC-SHA256',
      'X-Tos-Credential=AKTEST%2F20260902%2Fcn-beijing%2Ftos%2Frequest',
      'X-Tos-Date=20260902T083000Z',
      'X-Tos-SignedHeaders=host',
      'X-Tos-Signature=',
    ]) {
      expect(url, contains(part), reason: '缺了 $part');
    }
  });

  test('同样的输入签出同样的结果——不然没法排查', () {
    expect(signer.presignGet('a.zip', now: at),
        signer.presignGet('a.zip', now: at));
  });

  test('换个对象、换个时刻，签名就不一样', () {
    final a = signer.presignGet('a.zip', now: at);
    final b = signer.presignGet('b.zip', now: at);
    final c = signer.presignGet('a.zip', now: at.add(const Duration(days: 1)));
    expect(a, isNot(b));
    expect(a, isNot(c));
  });

  test('有效期写进链接里：临时链接才是私有存放的意义', () {
    final url =
        signer.presignGet('a.zip', ttl: const Duration(minutes: 5), now: at);
    expect(url, contains('X-Tos-Expires=300'));
  });

  test('对象键里的中文和空格要转义，不能直接拼进 URL', () {
    final url = signer.presignGet('releases/新 版.zip', now: at);
    expect(url, isNot(contains(' ')));
    expect(url, contains('%E6%96%B0%20%E7%89%88.zip'));
  });
}
