import 'script_doc.dart';

/// 划词建的镜头该插在第几个位置。
///
/// **不能追加到末尾**：人先划句尾、再划句首是常事（想到哪划到哪），
/// 追加的话镜头顺序就和台词顺序反了，画面会按错的次序播出去。
///
/// 规则：排在**第一个词序更靠后的绑词镜之前**。中间的自由镜留在原处
/// ——它们填的是前一个绑词镜之后的空隙，新镜应该排在它们后面。
int insertIndexForWords(List<LineShot> shots, int startWord) {
  for (var i = 0; i < shots.length; i++) {
    final s = shots[i];
    if (s.boundToWords && s.startWord! > startWord) return i;
  }
  return shots.length;
}
