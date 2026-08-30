import '../models/semantic_unit.dart';
import 'picked_material.dart';

/// 一条成片里挑的素材，产品露出的品牌必须是同一个。
///
/// **为什么这是硬约束**：台词说「滴露新款消毒液」，画面却是若也洗发水
/// 直播间（背景还有 logo 墙）——片子自己打自己的脸。2026-08-28 真机上就
/// 这样交付过一条成片（U3S2 的直播带货镜头用了若也 Rove 的直播间）。
///
/// 而 `--exclude-projects <原片项目>` **反而放大这个风险**：排掉原项目之后，
/// 语义检索会把最像的别家品牌素材顶上来。那个参数只懂项目 id，不懂品牌。
///
/// 判据不需要知道「本片是什么品牌」——**一条片子里出现两个牌子，本身就是
/// 错的**。这个信号立刻可用，不依赖原片重新打标。

/// 一次品牌冲突：这条片子里出现了几个不同的牌子，各自来自哪几条素材。
class BrandConflict {
  /// 出现的品牌（按素材顺序，保留模型给的原写法——那是给人认的）
  final List<String> brands;

  final Map<String, List<int>> _byBrand;

  const BrandConflict._(this.brands, this._byBrand);

  /// 这个牌子来自哪几条素材
  List<int> materialsOf(String brand) => _byBrand[brand] ?? const [];
}

/// 找出品牌冲突；只有一个牌子（或一个都没有）时返回 null。
///
/// **纯场景镜头不参与**：没有产品露出的素材随便哪个项目拍的都行。
/// **还没查过的也不参与**：不知道不等于冲突。
BrandConflict? brandConflict(List<PickedMaterial> picked) {
  final groups = <_BrandGroup>[];
  for (final m in picked) {
    final brand = m.productBrand;
    if (brand == null) continue;
    final norm = _norm(brand);
    if (norm.isEmpty) continue;
    (groups.firstWhere((g) => g.matches(norm),
            orElse: () => _added(groups, _BrandGroup()))
          ..absorb(norm, brand))
        .ids
        .add(m.id);
  }
  if (groups.length < 2) return null;
  return BrandConflict._(
    [for (final g in groups) g.label],
    {for (final g in groups) g.label: List.unmodifiable(g.ids)},
  );
}

_BrandGroup _added(List<_BrandGroup> groups, _BrandGroup g) {
  groups.add(g);
  return g;
}

/// 同一个牌子的所有写法。
///
/// 为什么要攒别名而不是只留一个 key：模型给的品牌名不稳定，同一个牌子会
/// 写成「滴露」「Dettol」「滴露 Dettol」。只留第一个见到的写法，
/// 后面来的「Dettol」就和「滴露」对不上，会报出一堆假冲突。
class _BrandGroup {
  final Set<String> aliases = {};
  final List<int> ids = [];

  /// 展示用的写法：留最长的那个（信息最全）
  String label = '';

  bool matches(String norm) =>
      aliases.any((a) => norm.contains(a) || a.contains(norm));

  void absorb(String norm, String original) {
    aliases.add(norm);
    if (original.length > label.length) label = original;
  }
}

String _norm(String brand) =>
    brand.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// 品牌冲突的说法。**点名品牌和素材**——只说一句「品牌不一致」等于让人
/// 自己去一条条翻，那还不如不说。
String? brandConflictNotice(List<PickedMaterial> picked) {
  final conflict = brandConflict(picked);
  if (conflict == null) return null;
  final lines = [
    for (final b in conflict.brands)
      '$b：素材 ${conflict.materialsOf(b).join('、')}',
  ];
  return '挑的素材里出现了 ${conflict.brands.length} 个不同品牌，'
      '成片会出现台词说的是一个牌子、画面里摆的是另一个：\n'
      '${lines.join('\n')}\n'
      '产品露出的镜头必须换成本品牌的素材；纯场景镜头才可以跨项目挑。';
}

/// 原片露的是什么牌子。
///
/// **「候选之间打架」这个判据有个缺口**：一条片子的候选全是若也（而原片是
/// 滴露）时，候选之间毫无冲突，可整条片子都错了。参照只能来自原片自己的
/// 产品露出镜头——任务名和项目名靠不住（会改名、会合并项目），
/// 素材描述里也从来不写品牌。
///
/// 按出现次数最多的那个算：一条片子里偶尔混进一两个别家产品的镜头
/// （比如对比测评）不该把整片的品牌带偏。
///
/// 老任务（打标那会儿还没记品牌）返回 null——**不知道不等于错**，
/// 那时只靠「候选之间打不打架」这一条判据。
String? sourceBrandOf(List<SemanticUnit> units) {
  final count = <String, int>{};
  final label = <String, String>{};
  for (final u in units) {
    for (final s in u.shots) {
      final brand = s.productBrand;
      if (brand == null || brand.trim().isEmpty) continue;
      final key = _norm(brand);
      count[key] = (count[key] ?? 0) + 1;
      final seen = label[key];
      if (seen == null || brand.length > seen.length) label[key] = brand;
    }
  }
  if (count.isEmpty) return null;
  final top = count.entries.reduce((a, b) => b.value > a.value ? b : a);
  return label[top.key];
}

/// 挑的素材和原片不是一个牌子。
///
/// 和 [brandConflictNotice] 是两条互补的判据：那条抓「候选之间打架」，
/// 这条抓「候选一致、但整条都跑到别家去了」。
String? brandMismatchNotice({
  required List<PickedMaterial> picked,
  required String? sourceBrand,
}) {
  if (sourceBrand == null) return null;
  final source = _norm(sourceBrand);
  final wrong = <String, List<int>>{};
  for (final m in picked) {
    final brand = m.productBrand;
    if (brand == null) continue;
    final norm = _norm(brand);
    if (norm.contains(source) || source.contains(norm)) continue;
    wrong.putIfAbsent(brand, () => []).add(m.id);
  }
  if (wrong.isEmpty) return null;
  final lines = [
    for (final e in wrong.entries) '${e.key}：素材 ${e.value.join('、')}',
  ];
  return '原片里露出的产品是「$sourceBrand」，'
      '但挑的素材里有 ${wrong.values.fold<int>(0, (n, v) => n + v.length)} 条'
      '露的是别家的：\n${lines.join('\n')}\n'
      '台词说的和画面里摆的对不上，产品露出的镜头得换成本品牌的素材。';
}
