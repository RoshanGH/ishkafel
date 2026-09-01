/// Agent 能用的检索方式。**与界面上人能用的完全一致**。
///
/// 用户的要求原话：「让 Agent 使用所有软件可以使用的功能。」
/// 此前软件有 5 种检索，Agent 只能用 2 种——尤其缺**以图搜图**，
/// 而复刻场景最该用它：手里就有参考镜的画面，直接拿去找像的最准。
enum SearchMode {
  tags(
    'tags',
    '按标签找',
    '参考镜打过标时的默认路子。标签是受控词表，命中率稳，但同一组标签下的'
        '素材可能几十条，还要再筛',
  ),
  content(
    'content',
    '按画面描述找',
    '自己写一句画面（「一只手在厨房台面上举着喷雾瓶」）去搜。'
        '**描述的是画面不是台词**——拿台词搜画面描述是行不通的',
  ),
  image(
    'image',
    '以图搜图（找相似画面）',
    '**复刻场景最该用这个**：手里已经有一条像的素材，直接拿它去找同类。'
        '比用文字描述准得多——画面的很多东西说不清楚',
  ),
  voiceover(
    'voiceover',
    '按口播词找',
    '素材自己带的口播里说了什么。找「有人在说这句话」的素材时用',
  ),
  refImage(
    'ref-image',
    '拿参考镜的首帧找（画面相似）',
    '**复刻最该用的那一种**：要复刻的画面就在手上（参考片这一镜的首帧），'
        '直接拿它去找同类，比让模型先把画面写成一句话、再拿那句话去匹配'
        '别人写的另一句话准得多——中间那层转译不稳，同一个镜头两次写出来的'
        '措辞不一样，搜出来的东西就跟着变。'
        '用 --materials 指定拿这一句的第几个参考镜（从 1 起，缺省第 1 个）',
  ),
  name(
    'name',
    '按素材名找',
    '知道素材大概叫什么（同一批常有命名规律）时用',
  );

  const SearchMode(this.wire, this.label, this.whenToUse);

  final String wire;
  final String label;

  /// 什么时候该用它——手册里列出来，Agent 才选得对
  final String whenToUse;

  /// 要不要给一条素材（以图搜图靠的是某条素材的画面）
  bool get needsMaterial => this == SearchMode.image;

  /// 要不要给关键词
  bool get needsKeyword =>
      this == SearchMode.content ||
      this == SearchMode.voiceover ||
      this == SearchMode.name;

  static SearchMode? parse(String? name) {
    for (final m in SearchMode.values) {
      if (m.wire == name) return m;
    }
    // 认不出就说认不出：静默退回某一种，会让 Agent 以为自己搜的是 A、
    // 实际搜的是 B，而候选看起来都「像那么回事」
    return null;
  }
}
