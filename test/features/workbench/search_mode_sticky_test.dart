import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/features/workbench/search_mode_policy.dart';

void main() {
  group('标签用不了时落到画面描述，能用了要回得来', () {
    test('标签正常时就用标签', () {
      final next = nextSearchMode(
        current: CandidateSearchMode.tag,
        tagAvailable: true,
        tagPending: false,
        descriptionSupported: true,
        userPinned: false,
      );

      expect(next.mode, CandidateSearchMode.tag);
      expect(next.autoFellBack, isFalse);
    });

    test('这个镜头没标签时落到画面描述，并记下这是自动落的', () {
      final next = nextSearchMode(
        current: CandidateSearchMode.tag,
        tagAvailable: false,
        tagPending: false,
        descriptionSupported: true,
        userPinned: false,
      );

      expect(next.mode, CandidateSearchMode.description);
      expect(next.autoFellBack, isTrue);
    });

    test('换到一个标签正常的镜头时自动切回标签——这是原来漏掉的', () {
      final next = nextSearchMode(
        current: CandidateSearchMode.description,
        tagAvailable: true,
        tagPending: false,
        descriptionSupported: true,
        userPinned: false,
        autoFellBack: true,
      );

      expect(next.mode, CandidateSearchMode.tag,
          reason: '只往下切不往回切的话，碰到一个没标签的镜头之后，'
              '后面每一个镜头都在用画面描述搜，用户还以为在按标签搜');
      expect(next.autoFellBack, isFalse);
    });

    test('用户自己选的画面描述不许被抢回去', () {
      final next = nextSearchMode(
        current: CandidateSearchMode.description,
        tagAvailable: true,
        tagPending: false,
        descriptionSupported: true,
        userPinned: true,
        autoFellBack: false,
      );

      expect(next.mode, CandidateSearchMode.description,
          reason: '用户明确点过的选择，程序不该悄悄改掉');
    });

    test('标签表还在读时按兵不动——「暂时不能用」不等于「不能用」', () {
      final next = nextSearchMode(
        current: CandidateSearchMode.tag,
        tagAvailable: false,
        tagPending: true,
        descriptionSupported: true,
        userPinned: false,
      );

      expect(next.mode, CandidateSearchMode.tag);
      expect(next.autoFellBack, isFalse);
    });

    test('整体替换没有画面描述这条路，一律回到标签', () {
      final next = nextSearchMode(
        current: CandidateSearchMode.description,
        tagAvailable: false,
        tagPending: false,
        descriptionSupported: false,
        userPinned: true,
      );

      expect(next.mode, CandidateSearchMode.tag);
    });

    test('搜图模式不受影响——它是用户手动进的', () {
      final next = nextSearchMode(
        current: CandidateSearchMode.image,
        tagAvailable: true,
        tagPending: false,
        descriptionSupported: true,
        userPinned: true,
      );

      expect(next.mode, CandidateSearchMode.image);
    });
  });
}
