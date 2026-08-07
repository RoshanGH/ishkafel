import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

void main() {
  group('整体替换：选几个，指一个当预览版', () {
    test('默认是第一个选中的', () {
      final r = UnitReplacement.whole(const [71, 72, 73]);

      expect(r.wholePreviewId, 71);
    });

    test('可以指定别的', () {
      final r = UnitReplacement.whole(const [71, 72, 73], previewId: 72);

      expect(r.wholePreviewId, 72);
    });

    test('指定了一个没选中的就当没指定，退回第一个', () {
      final r = UnitReplacement.whole(const [71, 72], previewId: 99);

      expect(r.wholePreviewId, 71,
          reason: '方案是存在盘上的，用户取消勾选之后预览指向可能就没了');
    });

    test('一个都没选时没有预览版', () {
      expect(UnitReplacement.whole(const []).wholePreviewId, isNull);
    });

    test('候选数不受预览版影响——预览是预览，导出照样出三条', () {
      expect(UnitReplacement.whole(const [71, 72, 73], previewId: 73).factor, 3);
    });
  });

  group('镜头替换：每个镜头各指一个预览版', () {
    test('默认各取自己的第一个', () {
      final r = UnitReplacement.perShot(const {
        0: [11, 12],
        2: [21],
      });

      expect(r.shotPreviewId(0), 11);
      expect(r.shotPreviewId(2), 21);
    });

    test('可以逐个镜头指定', () {
      final r = UnitReplacement.perShot(const {
        0: [11, 12],
        2: [21, 22],
      }, previewIds: const {0: 12, 2: 22});

      expect(r.shotPreviewId(0), 12);
      expect(r.shotPreviewId(2), 22);
    });

    test('指到没选中的候选上就退回第一个', () {
      final r = UnitReplacement.perShot(const {
        0: [11, 12]
      }, previewIds: const {0: 99});

      expect(r.shotPreviewId(0), 11);
    });

    test('没替换的镜头没有预览版', () {
      final r = UnitReplacement.perShot(const {
        0: [11]
      });

      expect(r.shotPreviewId(5), isNull);
    });
  });

  group('存得住', () {
    test('整体替换的预览版存了再读回来还在', () {
      final r = UnitReplacement.whole(const [71, 72], previewId: 72);

      expect(UnitReplacement.tryFromJson(r.toJson())!.wholePreviewId, 72);
    });

    test('镜头替换的预览版存了再读回来还在', () {
      final r = UnitReplacement.perShot(const {
        0: [11, 12],
        3: [31],
      }, previewIds: const {0: 12});

      final back = UnitReplacement.tryFromJson(r.toJson())!;

      expect(back.shotPreviewId(0), 12);
      expect(back.shotPreviewId(3), 31);
    });

    test('老存档没有预览版字段时退回第一个，不炸', () {
      final back = UnitReplacement.tryFromJson({
        'mode': 'whole',
        'wholeCandidateIds': [71, 72],
        'shotCandidateIds': <String, dynamic>{},
      })!;

      expect(back.wholePreviewId, 71);
    });

    test('预览版字段畸形时也退回第一个', () {
      final back = UnitReplacement.tryFromJson({
        'mode': 'whole',
        'wholeCandidateIds': [71, 72],
        'wholePreviewId': '不是数字',
        'shotCandidateIds': <String, dynamic>{},
      })!;

      expect(back.wholePreviewId, 71);
    });
  });
}
