import 'voice_plan.dart';

/// 一个可选音色及其适用场景
class VoiceOption {
  final VoiceRef ref;

  /// 控制台里的「推荐场景」，用来分组展示
  final String scene;

  /// 语种（cn / en）
  final String language;

  const VoiceOption({
    required this.ref,
    required this.scene,
    this.language = 'cn',
  });
}

/// 豆包语音合成大模型 2.0 的音色目录。
///
/// **写死一份而不是拉接口**：火山没有开放「列出我账号下可用音色」的 API，
/// 音色只在控制台的音色库页面里看得到。写死的代价是新增音色要改代码，
/// 但比让用户手抄一串 `zh_female_..._uranus_bigtts` 强得多。
///
/// 这里是控制台里 99 个音色的**常用子集**。要加音色，从
/// 控制台 > 音色库 抄下「音色名称」与 `Voice_type` 两列即可。
abstract final class VoiceCatalog {
  static const List<VoiceOption> all = [
    // 通用场景——口播、解说这类正经内容优先从这里挑
    VoiceOption(
      ref: VoiceRef(id: 'zh_female_vv_uranus_bigtts', name: 'vivi 2.0'),
      scene: '通用场景',
    ),
    VoiceOption(
      ref: VoiceRef(id: 'zh_female_xiaohe_uranus_bigtts', name: '小何'),
      scene: '通用场景',
    ),
    VoiceOption(
      ref: VoiceRef(id: 'zh_male_m191_uranus_bigtts', name: '云舟'),
      scene: '通用场景',
    ),
    VoiceOption(
      ref: VoiceRef(id: 'zh_male_taocheng_uranus_bigtts', name: '小天'),
      scene: '通用场景',
    ),
    // 角色扮演——情绪更外放，适合夸张的带货腔
    VoiceOption(
      ref: VoiceRef(id: 'saturn_zh_female_cancan_tob', name: '知性灿灿'),
      scene: '角色扮演',
    ),
    VoiceOption(
      ref: VoiceRef(id: 'saturn_zh_female_keainvsheng_tob', name: '可爱女生'),
      scene: '角色扮演',
    ),
    VoiceOption(
      ref: VoiceRef(id: 'saturn_zh_female_tiaopigongzhu_tob', name: '调皮公主'),
      scene: '角色扮演',
    ),
    VoiceOption(
      ref: VoiceRef(
          id: 'saturn_zh_male_shuanglangshaonian_tob', name: '爽朗少年'),
      scene: '角色扮演',
    ),
    VoiceOption(
      ref: VoiceRef(id: 'saturn_zh_male_tiancaitongzhuo_tob', name: '天才同桌'),
      scene: '角色扮演',
    ),
    VoiceOption(
      ref: VoiceRef(id: 'en_male_tim_uranus_bigtts', name: 'Tim'),
      scene: '通用场景',
      language: 'en',
    ),
  ];

  /// 按推荐场景分组，保持目录里的原始顺序
  static Map<String, List<VoiceOption>> get byScene {
    final out = <String, List<VoiceOption>>{};
    for (final v in all) {
      (out[v.scene] ??= []).add(v);
    }
    return Map.unmodifiable({
      for (final e in out.entries) e.key: List<VoiceOption>.unmodifiable(e.value),
    });
  }

  /// 按名字或 id 过滤。空关键词返回全部——一进来就让用户想关键词，
  /// 等于把「先看看有哪些」这条路堵死。
  static List<VoiceOption> search(String keyword) {
    final k = keyword.trim().toLowerCase();
    if (k.isEmpty) return all;
    return List.unmodifiable([
      for (final v in all)
        if (v.ref.name.toLowerCase().contains(k) ||
            v.ref.id.toLowerCase().contains(k) ||
            v.scene.toLowerCase().contains(k))
          v,
    ]);
  }

  static VoiceOption? byId(String id) {
    for (final v in all) {
      if (v.ref.id == id) return v;
    }
    return null;
  }
}
