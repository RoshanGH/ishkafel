import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/source_print.dart';

/// 同一条片子导入三次，切出 **3 / 4 / 5 个单元**——验收 Agent 实测：
/// 同一个文件、同样的标签组、同样 75302ms，三种结构。
///
/// 语义切分是 LLM 干的、有随机性。后果有两个：
/// - 方案文件不能跨任务复用：`unit 2 shot 3` 这个坐标在新任务里指向别的画面，
///   重新导入一次，之前挑素材的工作全作废
/// - 「1:1 复刻」打折扣：3 个单元和 5 个单元切出来的边界不一样
///
/// 解法是按**源文件内容**缓存切分结果：同一个文件重新导入，直接复用。
/// 顺带省掉一次 ASR + LLM（那是真金白银）。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sp'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, List<int> bytes) =>
      File('${dir.path}/$name')..writeAsBytesSync(bytes);

  test('同一个文件算出同一个指纹', () {
    final a = write('a.mp4', List.generate(5000, (i) => i % 251));
    final b = write('b.mp4', List.generate(5000, (i) => i % 251));

    expect(sourcePrintOf(a.path), sourcePrintOf(b.path));
  });

  test('内容不同，指纹就不同', () {
    final a = write('a.mp4', List.generate(5000, (i) => i % 251));
    final b = write('b.mp4', List.generate(5000, (i) => (i + 1) % 251));

    expect(sourcePrintOf(a.path), isNot(sourcePrintOf(b.path)));
  });

  test('长度不同，指纹就不同——哪怕开头一模一样', () {
    final a = write('a.mp4', List.generate(5000, (i) => i % 251));
    final b = write('b.mp4', List.generate(6000, (i) => i % 251));

    expect(sourcePrintOf(a.path), isNot(sourcePrintOf(b.path)));
  });

  test('只在结尾差一个字节也认得出来', () {
    final base = List.generate(400000, (i) => i % 251);
    final a = write('a.mp4', base);
    final b = write('b.mp4', [...base.sublist(0, base.length - 1), 99]);

    expect(sourcePrintOf(a.path), isNot(sourcePrintOf(b.path)),
        reason: '只读开头的话，剪掉结尾的片子会被当成同一条');
  });

  test('文件不在就返回 null，不硬造一个指纹', () {
    expect(sourcePrintOf('${dir.path}/没有这个.mp4'), isNull);
  });
}
