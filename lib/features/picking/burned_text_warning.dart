import '../../core/replacement/brand_consistency.dart';
import '../../core/replacement/picked_material.dart';

/// 画面自查（烧字、产品露出品牌）的说法，集中在这里定。
///
/// 为什么单独一个文件：托盘、候选卡、导出前确认三处都要说这件事，
/// 说法散在三处必然走样——而这句话的作用是让人当场决定「换一条」，
/// 说不清就等于没提醒。

/// 一条素材的警告文案；画面干净或还没查过时为 null。
///
/// 「还没查过」不出警告是有意的：那是我们的能力缺口，不是这条素材的问题，
/// 把它渲染成红色会让每一条素材都在报警，真正有问题的那条反而淹掉了。
/// 但它也绝不能被说成「画面干净」——见 [PickedMaterial.burnedText]。
String? burnedTextWarning(PickedMaterial? material) {
  if (material == null || !material.hasBurnedText) return null;
  final words = material.burnedText!.join('、');
  return '画面上烧着字：「$words」。换上它之后我们还要再烧一行台词字幕，'
      '两层字会叠在一起——建议换一条';
}

/// 导出前的汇总：**点名**是哪几个位置的哪几条，不是笼统一句「有素材有问题」。
/// 笼统的提示等于让用户自己去一个个翻，那还不如不提。
String? burnedTextSummary(
    List<({String label, PickedMaterial material})> picks) {
  final bad = [
    for (final p in picks)
      if (p.material.hasBurnedText)
        '${p.label}：${p.material.burnedText!.join('、')}',
  ];
  if (bad.isEmpty) return null;
  return '这 ${bad.length} 条素材画面上本来就烧着字，'
      '成片会出现两层字幕：\n${bad.join('\n')}';
}

/// 「这条素材露的是别家的牌子」的说法。
///
/// [conflicting] 由调用方按整份已选素材算（见 [brandConflict]）——单看
/// 一条素材是判不出品牌错位的：一条片子全用若也的素材没问题，
/// 问题是**一条片子里出现两个牌子**。
String? brandWarning(PickedMaterial? material, {required bool conflicting}) {
  if (material == null || !conflicting || !material.hasProduct) return null;
  return '这条画面里露出的产品是「${material.productBrand}」。'
      '这条片子挑的素材里不止一个牌子——台词说的和画面里摆的对不上，'
      '产品露出的镜头得换成本品牌的';
}

/// 播报条上的**一句话版**。
///
/// 播报条一行就那么宽，超出直接省略号——托盘和导出页可以摆多行细节，
/// 这里只有一句话的余地。那一句要说清「出了什么事、多严重」，
/// 细节让人自己去那两处看。
///
/// 都没问题时返回 null：**没事也说一句，只会淹掉真有事那一句**。
String? burnedTextBroadcastLine(List<PickedMaterial> picked) {
  final n = picked.where((m) => m.hasBurnedText).length;
  if (n == 0) return null;
  return '有 $n 条素材画面上烧着字，成片会出现两层字幕';
}

/// 品牌错位的一句话版。两条判据合成一句：
/// 候选之间打架说「几个牌子」，候选全跑到别家说「原片是什么牌子」。
String? brandBroadcastLine({
  required List<PickedMaterial> picked,
  required String? sourceBrand,
}) {
  if (brandMismatchNotice(picked: picked, sourceBrand: sourceBrand) != null) {
    final wrong = <String>{
      for (final m in picked)
        if (m.hasProduct && !_sameBrand(m.productBrand!, sourceBrand!))
          m.productBrand!,
    };
    return '原片是「$sourceBrand」，挑的素材里有${_brief(wrong)}';
  }
  final conflict = brandConflict(picked);
  if (conflict == null) return null;
  return '挑的素材里有${_brief(conflict.brands)}，牌子对不上';
}

bool _sameBrand(String a, String b) {
  final x = a.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  final y = b.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  return x.contains(y) || y.contains(x);
}

/// 牌子多了就只点前两个，剩下的写个数——一行放不下六个牌子，
/// 撑爆的话前面「出了什么事」那半句反而被省略号吃掉
String _brief(Iterable<String> brands) {
  final list = brands.toList();
  if (list.length <= 2) return '「${list.join('」「')}」';
  return '「${list.take(2).join('」「')}」等 ${list.length} 个牌子';
}
