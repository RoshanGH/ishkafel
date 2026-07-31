import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_failure.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';

void main() {
  group('失败分类', () {
    test('CLI 没装（子进程根本起不来）→ cliMissing', () {
      final error = ProcessException(
          'miaoa', const [], 'No such file or directory', 2);
      expect(classifyMiaoaFailure(error), MiaoaFailureKind.cliMissing);
    });

    test('401 / 未登录 / token 失效 → unauthorized', () {
      for (final stderr in const [
        'request failed: 401 Unauthorized',
        '未登录，请先执行 miaoa auth login',
        'token expired',
      ]) {
        expect(classifyMiaoaFailure(MiaoaException('miaoa 调用失败：$stderr')),
            MiaoaFailureKind.unauthorized,
            reason: stderr);
      }
    });

    test('403 → forbidden（不创建占位资源、不重试）', () {
      expect(classifyMiaoaFailure(const MiaoaException('403 Forbidden')),
          MiaoaFailureKind.forbidden);
    });

    test('404 → notFound（停止并返回原始错误，不重试）', () {
      expect(classifyMiaoaFailure(const MiaoaException('404 not found')),
          MiaoaFailureKind.notFound);
    });

    test('网络类错误 → network', () {
      for (final stderr in const [
        'dial tcp 10.0.0.1:443: connect: connection refused',
        'context deadline exceeded (Client.Timeout exceeded)',
        'lookup api.miaoa.cn: no such host',
      ]) {
        expect(classifyMiaoaFailure(MiaoaException(stderr)),
            MiaoaFailureKind.network,
            reason: stderr);
      }
    });

    test('认不出来的错误 → unknown，绝不冒充成别的原因', () {
      expect(classifyMiaoaFailure(const MiaoaException('segmentation fault')),
          MiaoaFailureKind.unknown);
      expect(classifyMiaoaFailure(StateError('x')), MiaoaFailureKind.unknown);
    });
  });

  group('引导文案：每种失败都要能照着做', () {
    test('每种失败都有非空中文引导，且不含原始异常文本', () {
      for (final kind in MiaoaFailureKind.values) {
        final text = miaoaFailureGuidance(kind);
        expect(text, isNotEmpty, reason: '$kind');
        expect(text.contains('Exception'), isFalse, reason: '$kind 不该把异常类名摊给用户');
      }
    });

    test('未登录的引导给出确切命令，并且明确要用户手动重试（不自动重试）', () {
      final text = miaoaFailureGuidance(MiaoaFailureKind.unauthorized);
      expect(text, contains('miaoa auth login'));
      expect(text, contains('重试'));
    });

    test('CLI 缺失的引导指向安装与 PATH', () {
      final text = miaoaFailureGuidance(MiaoaFailureKind.cliMissing);
      expect(text, contains('miaoa'));
      expect(text, contains('PATH'));
    });

    test('miaoaFriendlyMessage 直接把异常翻译成人话', () {
      expect(miaoaFriendlyMessage(const MiaoaException('401 Unauthorized')),
          miaoaFailureGuidance(MiaoaFailureKind.unauthorized));
    });
  });
}
