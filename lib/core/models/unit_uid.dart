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

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

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

/// 给还没有身份的单元补发（**随机**），并把撞上的换掉。
///
/// **只用在编辑器收下单元这一个入口**：拆分/合并/手动添加造出来的新单元
/// 还是空身份，这里要发的是一个真正独一无二的新身份，掷随机数没问题——
/// 反正只发这一次，以后不会有第二次独立的「掷号」要跟它对上。
///
/// **读档补发不要用这个，要用 [ensureUnitUidsDeterministic]**——那边的
/// 场景是同一份磁盘数据可能被独立解析很多次（`findById`、`findAll`、
/// 另一个进程），掷随机数每次都会掷出不一样的值，两次读永远对不上号
/// （2026-09-17 真机复审揪出来的：这不是并发窗口才有的小概率事件，是
/// 零时间差也必然发生的结构性错位）。
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

/// 按内容推导一个身份——**不掷随机数，同样的输入永远推出同样的输出**。
///
/// 只用于 [ensureUnitUidsDeterministic]（读档补发）。`taskId` 保证跨任务
/// 不撞；`index` 保证同一个任务内、就算两个单元的起止毫秒数碰巧一样
/// （比如两条空白任务的占位分子）也不会推出同一个值；`startMs`/`endMs`
/// 把「这一格具体是什么」也编进去，多一层保险。
String deriveUnitUidFromContent(
        String taskId, int index, int startMs, int endMs) =>
    sha256
        .convert(utf8.encode('$taskId#$index#$startMs#$endMs'))
        .toString()
        .substring(0, 12);

/// 给还没有身份的单元补发（**确定性**，不掷随机数）。
///
/// **只用在读档这一个入口**（`RenewTask.fromJson`）：磁盘上同一份数据会被
/// `findById`、`findAll`、甚至另一个进程各自独立解析，`TaskMutation` 靠
/// uid 在两次独立的读之间把同一个单元重新认出来——如果补发的身份每次都
/// 不一样，这条认领永远失败，等价于「单元刚被删掉了」，改动因此白做。
///
/// **编辑器里真正新建/拆分出来的单元不能用这个，要用 [ensureUnitUids]**
/// （随机）——两个毫不相干的单元完全可能用一模一样的
/// `taskId+index+startMs+endMs`，确定性推导在那个场景下会把两个不相干
/// 的东西认成同一个，不是补身份，是发生身份碰撞。
///
/// 一个都不用改时原样返回 [units] 本身，理由同 [ensureUnitUids]。
List<SemanticUnit> ensureUnitUidsDeterministic(
    String taskId, List<SemanticUnit> units) {
  final seen = <String>{};
  var changed = false;
  final out = <SemanticUnit>[];
  for (final unit in units) {
    if (!isUnitUid(unit.uid) || !seen.add(unit.uid)) {
      var uid =
          deriveUnitUidFromContent(taskId, unit.index, unit.startMs, unit.endMs);
      // 万一推出来的撞上同一批里另一个单元（哈希碰撞，概率极低）：
      // 不能退回随机数，那会破坏「同样的输入永远推出同样的输出」这条
      // 保证——把 endMs 加上一个跟迭代顺序绑定的、同样确定性的偏移再推
      // 一次，直到不撞
      var salt = 0;
      while (!seen.add(uid)) {
        salt++;
        uid = deriveUnitUidFromContent(
            taskId, unit.index, unit.startMs, unit.endMs + salt);
      }
      out.add(unit.copyWith(uid: uid));
      changed = true;
      continue;
    }
    out.add(unit);
  }
  return changed ? out : units;
}
