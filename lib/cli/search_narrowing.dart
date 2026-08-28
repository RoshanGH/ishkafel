/// 这一轮检索是按什么收窄的
typedef Narrowing = ({bool narrowed, String? notice});

/// 检索有没有被约束住；没有就**明说**。
///
/// 真机翻车：任务选了「AI自然消毒液原子库」两个标签组，搜出来却混进
/// 大量 Hi!papa 防晒乳、Roye 洗护——跟滴露毫无关系。两道约束同时失效：
///
/// - `project` 是 null（`ui new-task` 没让人/Agent 选项目）
/// - 参考镜没打标 → 标签为空 → 检索不带任何标签条件
///
/// 两道都没有时就是**在全库里捞**。这时候搜回来的东西看着都「像那么回事」
/// （都是竖屏带货素材），Agent 挑不出问题，人拿到成片才发现品牌串了。
/// 所以宁可啰嗦一句，也不能让它以为搜到的就是对的。
Narrowing describeNarrowing({
  required List<int> projectIds,
  required List<int> tagIds,
}) {
  if (projectIds.isNotEmpty || tagIds.isNotEmpty) {
    return (narrowed: true, notice: null);
  }
  return (
    narrowed: false,
    notice: '这一轮是在**全库**里搜的——没有项目也没有标签可用来收窄，'
        '搜回来的可能是别的品牌（真机上混进过防晒乳和洗护）。'
        '收窄的办法：先 ishkafel script tag-ref <任务> --line N 给参考镜打标'
        '（标签就有了），或者建任务时指定项目',
  );
}
