/// 标签搜完了，这批结果到底能不能用。
///
/// **要害不在命中多少，在素材库怎么排**：按标签检索返回的是**按 id 倒序的
/// 最新一批**，没有任何相关性排序；画面描述语义搜才是按像不像排的。
///
/// 所以标签命中数一旦明显超出人愿意翻的页数，拿到的前几十条就跟这一镜要什么
/// 无关了。真机上 35 个镜头每一镜都是 `total: 11265`，第一镜要「女孩在书桌前
/// 情绪激动诉说」，首条给的是「户外街道上女士与男孩并排走着交谈」；
/// 同一镜换语义搜是 554 条，前十条几乎全是「女孩坐书桌前哭诉」。
///
/// 判出来不能用就该自动改走语义搜，并且**把换了这件事说出来**。
library;

/// 超过这么多条就认为「翻不完，前几页等于随机取样」。
///
/// 四页。再多没人会翻——Agent 看前一两页就要下判断，人也一样。
/// 命中一两页时前 50 条覆盖了大半，最新与最像的差别还不致命。
const int _unreviewablePages = 4;

/// 这批标签检索结果值不值得用。false = 该换画面描述语义搜
bool tagResultIsUsable({
  required int total,
  required int libraryTotal,
  required int returned,
  int pageSize = 50,
}) {
  // 一条都没有：话术类标签素材库里几乎没人打，搜不出不代表没素材
  if (total == 0) return false;
  // 一页就装得下，这 50 条就是全部命中，不存在取样问题
  if (total <= returned) return true;
  return total <= pageSize * _unreviewablePages;
}
