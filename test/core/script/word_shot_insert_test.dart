import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/word_shot_insert.dart';

/// 划词建的镜头要**插到正确位置**，不是追加到末尾。
///
/// 人先划句尾、再划句首是常事（想到哪划到哪）。追加到末尾的话，
/// 镜头顺序就和台词顺序反了，画面会按错的次序播出去。
void main() {
  LineShot bound(int s, int e) =>
      LineShot(materialId: s, name: 'b$s', durationMs: 9999, startWord: s, endWord: e);
  const free = LineShot(materialId: 99, name: '自由', durationMs: 9999);

  test('空行：直接放进去', () {
    expect(insertIndexForWords(const [], 0), 0);
  });

  test('先划了句尾，再划句首 → 句首排到前面', () {
    final shots = [bound(8, 10)];
    expect(insertIndexForWords(shots, 0), 0);
  });

  test('划中间的一段 → 排在两个绑词镜之间', () {
    final shots = [bound(0, 3), bound(8, 10)];
    expect(insertIndexForWords(shots, 5), 1);
  });

  test('划最后一段 → 追加到末尾', () {
    final shots = [bound(0, 3), bound(5, 8)];
    expect(insertIndexForWords(shots, 9), 2);
  });

  test('自由镜留在两个绑词镜之间——新镜插在下一个绑词镜之前', () {
    final shots = [bound(0, 3), free, bound(10, 12)];
    expect(insertIndexForWords(shots, 5), 2,
        reason: '自由镜填的是 0~3 之后的空隙，新镜排在它后面');
  });

  test('全是自由镜时追加到末尾——没有词序可依', () {
    expect(insertIndexForWords(const [free, free], 5), 2);
  });
}
