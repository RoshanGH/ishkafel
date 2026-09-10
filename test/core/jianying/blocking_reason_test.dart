import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/jianying/jianying_plan.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// **缺镜头这类问题一次说清，别让人补一行试一次。**
///
/// 2026-09-10 真机走查：脚本四句只挑了第一句的镜头，点「剪映」弹出的是
/// 「第 2 行还没挑镜头」——补完第 2 行再点，又说第 3 行。而这一类问题
/// 一眼就能看全，就该一次报全。导出那条线早就是全报的，两边不一致。
void main() {
  ScriptDoc fourLines() {
    var doc = ScriptDoc.empty().updateText(0, '第一句');
    doc = doc.insertAfter(0, text: '第二句');
    doc = doc.insertAfter(1, text: '第三句');
    doc = doc.insertAfter(2, text: '第四句');
    return doc;
  }

  test('三行都没挑镜头：一次说全，并成区间', () {
    final reason = jianyingBlockingReason(
        fourLines().setShotsById(fourLines().lines[0].id, const []));

    expect(reason, isNotNull);
    expect(reason, contains('第 1–4 行还没挑镜头'));
    expect(reason, contains('补齐这些再生成剪映草稿'));
  });

  test('全都挑好了就放行', () {
    var doc = fourLines();
    for (final line in doc.lines) {
      doc = doc.setShotsById(line.id, [
        const LineShot(materialId: 1, name: 'a', allocMs: 1000),
      ]);
    }

    expect(jianyingBlockingReason(doc), isNull);
  });

  test('挑了镜头但没分时长，也点名', () {
    var doc = fourLines();
    for (final line in doc.lines) {
      doc = doc.setShotsById(line.id, [
        const LineShot(materialId: 1, name: 'a', allocMs: 1000),
      ]);
    }
    doc = doc.setShotsById(doc.lines[1].id, [
      const LineShot(materialId: 2, name: 'b'),
    ]);

    expect(jianyingBlockingReason(doc), contains('第 2 行有镜头还没分时长'));
  });

  test('纯空行不点名——它本来就不占时间', () {
    final doc = ScriptDoc.empty();

    expect(jianyingBlockingReason(doc), isNull);
  });
}
