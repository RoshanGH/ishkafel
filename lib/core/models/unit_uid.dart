/// **台词语义单元的身份。**
///
/// 单元在列表里的位置（U1/U2/U3）是**成片顺序**，人一拖就变。可挂在单元上的
/// 那些东西——挑好的素材、换的音色、铺的配乐、手改的字幕、生成好的配音文件
/// ——过去全按位置记，于是每挪一次、每删一次都要人工把它们跟着搬一遍。
/// 搬漏一份不会报错，只会让成片悄悄变成另一个样子：
///
/// - 2026-09-07 配音漏搬：删掉 U2 之后，本该念 U3 的配音跑到 U2 身上
/// - 2026-09-08 替换方案漏搬：挪动之后挑好的素材留在原来那一格
/// - 2026-09-09 手改字幕漏搬：给 U3 改好的那句烧到 U2 的画面上
///
/// 产品负责人的原话：「这个台词语义单元应该有一个自己的编号，但不是 U1 U2
/// U3，因为它位置排序是有可能会变的。它这个编号下的所有数据都是跟着这个
/// 编号走。」
///
/// 所以给它发一个**永不变**的身份：切分出来那一刻生成，挪动、改边界、改台词、
/// 重新打标都不动它。界面上照旧显示 U1/U2/U3——那是位置，是给人看的。
library;

import 'dart:math';

import 'semantic_unit.dart';

const _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
final _random = Random();

/// 发一个新身份。12 位足够：一条片子几十个单元，撞上的概率可以忽略，
/// 而且 [ensureUnitUids] 会把撞上的那个换掉
String newUnitUid() =>
    List.generate(12, (_) => _alphabet[_random.nextInt(_alphabet.length)])
        .join();

/// 这个身份能用吗。空串 = 还没发过（老存档、或者刚 new 出来的）
bool isUnitUid(String? uid) => uid != null && uid.isNotEmpty;

/// 给还没有身份的单元补发，并把撞上的换掉。
///
/// **两个入口一定要跑它**：读档（老存档没有这个字段）、以及编辑器收下单元
/// （拆分/合并/手动添加造出来的新单元还是空身份）。跑过之后就有一条保证：
/// **进了编辑器的单元一定有身份、而且互不相同**，别处可以放心拿它当键。
///
/// 一个都不用改时原样返回 [units] 本身——调用方靠 `identical` 就能判断
/// 要不要真的去动界面（每次刷新都无脑重建的话，undo 栈会被灌满）。
List<SemanticUnit> ensureUnitUids(List<SemanticUnit> units) {
  final seen = <String>{};
  var changed = false;
  final out = <SemanticUnit>[];
  for (final unit in units) {
    // 撞号的也要换：拆分是「左边留用原身份、右边发新的」，写错一处就会
    // 出现两个单元共用一个身份，那时挂在它下面的东西会同时落到两格上
    if (!isUnitUid(unit.uid) || !seen.add(unit.uid)) {
      var uid = newUnitUid();
      while (!seen.add(uid)) {
        uid = newUnitUid();
      }
      out.add(unit.copyWith(uid: uid));
      changed = true;
      continue;
    }
    out.add(unit);
  }
  return changed ? out : units;
}
