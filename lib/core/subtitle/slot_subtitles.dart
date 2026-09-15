import '../analysis/providers.dart' show AsrSentence;
import 'subtitle_overlay.dart';
import 'subtitle_track.dart';

/// 这一个坑位（某个视觉镜头）要烧哪几行字。**全 app 只有这一处说了算。**
///
/// 2026-09-08 真机：用户改完字幕，预览里没变、导出烧的还是旧的。原因是同一件
/// 事有三处各算各的——属性面板读了手改轨，而预览的变速切片和导出各自直接
/// 调 [subtitleLinesInSlot] 按 ASR 现算，谁也不认那条轨。改一处修不好，
/// 改三处下次还会漏第四处，所以收成一个函数，并加了架构测试盯着调用点。
///
/// 手改过就用手改的（空列表也算改过，那是「这一镜不要字幕」）；
/// 没改过才按 ASR 的词级时间戳现算。
List<SubtitleLine> subtitleLinesForSlot({
  required SubtitleTrack track,
  required List<AsrSentence> sentences,
  /// 这一镜所属单元的**身份**（不是位置）——手改的字幕按身份记，
  /// 单元怎么挪都还认得回来
  required String unitUid,
  required int shotIndex,
  required int slotStartMs,
  required int slotEndMs,

  /// 这一镜的底片是**挑来的素材**，不是原片
  /// （见 `docs/superpowers/specs/2026-09-14-底片-design.md`）。
  ///
  /// 那时 ASR 那份现算的**一个字都不能用**：时间戳量的是原片，画面却换成了
  /// 另一条片子，取出来的台词跟画面毫不相干——而它会被结结实实烧进成片。
  /// 手改过的照样认（人自己排的时间，他知道自己在干什么）。
  bool onMaterialBase = false,
}) =>
    track.linesOf(SubtitleSlot(unitUid: unitUid, shotIndex: shotIndex)) ??
    (onMaterialBase
        ? const []
        : subtitleLinesInSlot(
            sentences: sentences,
            slotStartMs: slotStartMs,
            slotEndMs: slotEndMs,
          ));

/// 这几行字的内容指纹，进渲染缓存的 key。
///
/// **必须连时间带文字一起进**：只按候选素材和坑位长度做 key 的话，人改完字
/// 再看预览，命中的还是上一次那段切片——表现为「改了没反应」，而这一步不进
/// 任何日志。没有字幕时返回空串，不参与拼 key（老任务的缓存照旧命中）。
String subtitleFingerprint(List<SubtitleLine> lines) => lines.isEmpty
    ? ''
    : '${[for (final l in lines) '${l.startMs}-${l.endMs}:${l.text}'].join('|').hashCode}';
