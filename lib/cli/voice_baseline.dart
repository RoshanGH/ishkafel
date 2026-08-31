import '../core/script/script_doc.dart';

/// 这一批配音用哪个音色当基调，以及**什么时候该拒绝开工**。
///
/// 音色是「错了整片废、而且每句都花钱」的那一类东西，所以取法必须明确：
///
/// 1. 命令行显式给的 `--voice`
/// 2. 本片基调 `doc.defaultVoiceId`（`script apply baseline` 写的就是它）
/// 3. 行上设过的音色——**排在基调后面**：行上那个多半是上一轮
///    「配完顺手固化」留下的，不该压过人后来定的基调
/// 4. 都没有 → **不撞运气**，拒绝并说清怎么定
///
/// 第 4 条是这个函数存在的理由。界面早就这么做了（生成前先卡住让人选，
/// 那儿的注释写着「真机上就是这么浪费掉的」），CLI 却直接拿目录里第一个
/// 去配整片——同一笔钱又烧了一遍，这次烧在验收 Agent 手上：它先设了基调，
/// CLI 无视，用别的音色配完 25 句；发现不对再显式写一遍、再配一轮。
class VoiceBaseline {
  /// 用哪个音色。[reject] 非空时它是 null
  final String? voiceId;

  /// 非空表示不该开工，这段话直接给调用方看
  final String? reject;

  const VoiceBaseline._({this.voiceId, this.reject});
}

VoiceBaseline resolveVoiceBaseline({
  required ScriptDoc doc,
  String? explicit,
}) {
  final picked = explicit ??
      doc.defaultVoiceId ??
      doc.lines
          .where((l) => l.voiceId != null)
          .map((l) => l.voiceId)
          .lastOrNull;
  if (picked != null && picked.isNotEmpty) {
    return VoiceBaseline._(voiceId: picked);
  }
  return VoiceBaseline._(
      reject: '这一片还没定音色，不能开工配音。\n'
          '**不给你随便挑一个**——音色不对整片都得重配，而每一句都是花钱的。\n'
          '先看有哪些：ishkafel voices\n'
          '再二选一定下来：\n'
          '· 定成全片基调（推荐，之后逐句都跟着它）：\n'
          '  ishkafel script apply baseline <任务> --file <写着 voiceId 的 json>\n'
          '· 或者这一次就用某个音色：ishkafel script voice <任务> --voice <音色 id>');
}
