import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/skipped_lines_summary.dart';

/// **别把同一个原因抄好几遍。**
///
/// 2026-09-09 设计走查真机：四行台词都没配音，编导台中栏就摞了四条橙字，
/// 一模一样，只有行号不同。该省的从来不是行号，是重复的那句原因。
void main() {
  _unitRanges();
  group('按原因归堆', () {
    test('四行同一个原因：并成一条', () {
      final text = summarizeSkippedLines({
        0: '还没生成配音（配音时长是这一行的根）',
        1: '还没生成配音（配音时长是这一行的根）',
        2: '还没生成配音（配音时长是这一行的根）',
        3: '还没生成配音（配音时长是这一行的根）',
      });

      expect(text, '第 1–4 行未进预览：还没生成配音（配音时长是这一行的根）');
      expect('\n'.allMatches(text), isEmpty, reason: '一个原因就该只占一行');
    });

    test('原因不同就分开说，各自说清是哪几行', () {
      final text = summarizeSkippedLines({
        0: '还没生成配音',
        1: '还没挑镜头',
        2: '还没生成配音',
      });

      expect(text, contains('第 1、3 行未进预览：还没生成配音'));
      expect(text, contains('第 2 行未进预览：还没挑镜头'));
    });

    test('一行都没漏时返回空——不该摆一块空的橙字', () {
      expect(summarizeSkippedLines(const {}), '');
    });
  });

  group('行号并区间', () {
    test('连着的并成区间', () {
      expect(lineNumberRanges([1, 2, 3, 4, 5]), '第 1–5 行');
    });

    test('不连的不许并——那会冤枉中间没出问题的行', () {
      expect(lineNumberRanges([1, 3]), '第 1、3 行');
      expect(lineNumberRanges([1, 2, 5, 6, 9]), '第 1、2、5、6、9 行');
    });

    test('挨着的两个写成顿号，比破折号顺', () {
      expect(lineNumberRanges([2, 3]), '第 2、3 行');
    });

    test('乱序进来也认', () {
      expect(lineNumberRanges([4, 1, 3, 2]), '第 1–4 行');
    });

    test('只有一行', () {
      expect(lineNumberRanges([7]), '第 7 行');
    });
  });
}

/// 单元名也一样：四个还能一个个念，十个就是一串噪音。
void _unitRanges() {
  group('单元名并区间', () {
    test('连号并成区间', () {
      expect(unitRanges([1, 2, 3, 4]), 'U2–U5');
    });

    test('不连的不许并', () {
      expect(unitRanges([0, 2]), 'U1、U3');
    });

    test('挨着的两个用顿号', () {
      expect(unitRanges([0, 1]), 'U1、U2');
    });

    test('只有一个', () {
      expect(unitRanges([5]), 'U6');
    });

    test('断成两段', () {
      expect(unitRanges([0, 1, 2, 5, 6]), 'U1–U3、U6、U7');
    });
  });
}
