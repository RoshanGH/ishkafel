import 'dart:io';

import 'package:path/path.dart' as p;

import '../analysis/audio_extractor.dart';
import '../analysis/providers.dart';
import '../analysis/scene_detector.dart';
import '../analysis/segmentation_builder.dart';
import '../models/video_info.dart';
import '../ffmpeg/ffprobe_service.dart';
import '../log/app_log.dart';
import 'reference_shots.dart';
import 'script_doc.dart';

/// 提取进行到哪一步了——界面拿它给用户交代（等待必须有交代）
enum ScriptTranscribeStage {
  extractingAudio('正在读取视频音频'),
  transcribing('正在识别台词'),
  cuttingShots('正在切参考分镜'),
  grouping('正在按台词语义分行');

  final String label;
  const ScriptTranscribeStage(this.label);
}

/// 提取失败：message 面向用户（中文、说清下一步），cause 只进日志
class ScriptTranscribeException implements Exception {
  final String message;
  final Object? cause;
  const ScriptTranscribeException(this.message, {this.cause});
  @override
  String toString() => message;
}

/// 「上传成片 → ASR → 脚本行」。
///
/// 脚本的两个来源之一（另一个是手写）：编导手里往往已经有一条参考成片，
/// 台词照着念一遍 ASR 就有了，没必要逐句敲。
///
/// **一句一行**：脚本行的粒度是「一句可配音的话」，直接取 ASR 按停顿切出
/// 的句子。不复用替换裂变的语义单元切分——那是段落级（一个卖点一段），
/// 拿来当脚本行会切出半篇文章长的行（真机验证撞到过）。
///
/// **没有台词的段落也成行**（画面行）：参考片开头的吸睛段、中间空镜、
/// 结尾产品定格常常一句话都不说，只按台词出行的话这些段等于不存在，
/// 复刻出来的片子会直接少掉它们。
///
/// 只产出**文本行**，不带时间戳进脚本——脚本成片里行的时长由配音定
/// （「配音时长是根」），参考片的原始时间轴在这里没有意义。
class ScriptTranscriber {
  final AudioExtractor audio;
  final AsrProvider asr;

  /// 视觉镜头切分（场景检测）。null = 不切（测试环境），
  /// 行的参考段就是整句一镜
  final SceneDetector? scenes;

  /// 探视频总时长——**末镜的终点**只能从这里来。没有它，参考片结尾那段
  /// 没有口播的定格镜头就无从成行（探不到时退回最后一句台词，见 [_durationMs]）。
  ///
  /// 默认就地装一个真的：默认执行器 systemProcessRunner 会解析内置的
  /// ffprobe，GUI 与 CLI 两边都不用各自记得传一遍（两边各装一套，迟早
  /// 出现「app 里提取出来是这样、命令行跑出来是那样」）。测试注入假的
  final FfprobeService probe;

  /// **台词语义分组**（分子）。和替换裂变用的是同一个 provider——
  /// 那边怎么切分子，这边就怎么切行。
  ///
  /// null = 没有方舟凭据或测试环境：退回「一句一单元」。那是**降级**，
  /// 不是正路——降级出来的行会碎，一个完整镜头可能被摊到好几行上
  final SemanticSplitter? splitter;

  /// 两层构树：单元边界吸附 + 单元内部按镜头边界切原子（严格包含）
  final SegmentationBuilder builder;

  /// PCM 中间产物的落脚处（用完即删，不留孤儿数据）
  final Directory workDir;

  ScriptTranscriber({
    required this.audio,
    required this.asr,
    this.scenes,
    this.splitter,
    this.builder = const SegmentationBuilder(),
    FfprobeService? probe,
    required this.workDir,
  }) : probe = probe ?? FfprobeService();

  /// 从视频提取脚本行。[onStage] 每进一步回调一次，供界面交代进度。
  ///
  /// 一句都识别不出来时抛 [ScriptTranscribeException]——静默返回空脚本
  /// 会让用户以为软件坏了。
  /// 只转写、不分行：手动传的参考视频用它拿「这段说了什么」
  /// （**只用于展示**——不回填脚本、不参与检索）
  Future<List<AsrSentence>> transcribeOnly(String videoPath) async {
    if (!File(videoPath).existsSync()) {
      throw ScriptTranscribeException('找不到这个视频文件：$videoPath');
    }
    await workDir.create(recursive: true);
    final pcmPath = p.join(workDir.path,
        'ref_asr_${DateTime.now().microsecondsSinceEpoch}.pcm');
    try {
      await audio.extractSamples(videoPath: videoPath, outPcmPath: pcmPath);
      return await asr.transcribe(pcmPath);
    } catch (e) {
      throw ScriptTranscribeException('参考视频的台词识别失败。', cause: e);
    } finally {
      try {
        File(pcmPath).deleteSync();
      } catch (_) {}
    }
  }

  Future<List<ScriptLine>> extract(
    String videoPath, {
    void Function(ScriptTranscribeStage stage)? onStage,
  }) async {
    if (!File(videoPath).existsSync()) {
      throw ScriptTranscribeException('找不到这个视频文件：$videoPath');
    }
    await workDir.create(recursive: true);
    final pcmPath = p.join(workDir.path,
        'script_asr_${DateTime.now().microsecondsSinceEpoch}.pcm');
    try {
      onStage?.call(ScriptTranscribeStage.extractingAudio);
      try {
        await audio.extractSamples(videoPath: videoPath, outPcmPath: pcmPath);
      } catch (e) {
        throw ScriptTranscribeException(
            '读取视频音频失败，请确认文件是完整的视频且本机 ffmpeg 可用。',
            cause: e);
      }

      onStage?.call(ScriptTranscribeStage.transcribing);
      final List<AsrSentence> sentences;
      try {
        sentences = await asr.transcribe(pcmPath);
      } catch (e) {
        throw ScriptTranscribeException(
            '台词识别失败（语音服务不可用或网络异常），请稍后重试。',
            cause: e);
      }
      // 视觉镜头层：整片跑一次场景检测，切点把片子切成完整镜头。
      // 检测失败不挡提取——镜头层是增强，行的参考段退回整句一镜
      var cuts = const <int>[];
      if (scenes != null) {
        onStage?.call(ScriptTranscribeStage.cuttingShots);
        try {
          cuts = await scenes!.detect(videoPath);
        } catch (e) {
          AppLog.warn('参考分镜切分失败（不影响提取）：$e');
        }
      }
      // **和替换裂变同一套切分**：先按台词语义分成单元（分子），
      // 再在单元内部按镜头边界切出参考分镜（原子）。
      // 一句一行是降级路径，不是正路——见 reference_shots.dart
      onStage?.call(ScriptTranscribeStage.grouping);
      final info = await _info(videoPath);
      final durationMs = info?.duration.inMilliseconds ?? 0;
      final fps = (info?.fps ?? 0) > 0 ? info!.fps : 25.0;
      final drafts = await _draftsOf(sentences);
      final units = builder.build(
        drafts: draftsWithVisualGaps(
            drafts: drafts,
            durationMs: durationMs > 0 ? durationMs : _lastSpokenMs(sentences)),
        shotBoundaryMs: cuts,
        silenceValleyMs: const [],
        videoDurationMs:
            durationMs > 0 ? durationMs : _lastSpokenMs(sentences),
        fps: fps,
      );
      final lines = linesFromUnits(units: units, sentences: sentences);
      if (!lines.any((l) => l.type == ScriptLineType.voiced)) {
        throw const ScriptTranscribeException(
            '这条视频里没有识别到任何台词——请确认它有人声口播。');
      }
      return lines;
    } finally {
      // 中间产物用完即弃（几分钟的 PCM 有几十 MB）
      try {
        File(pcmPath).deleteSync();
      } catch (_) {}
    }
  }

  /// 语义分组。**分不了组就退回一句一单元**，并说出来——那会让行变碎，
  /// 一个完整镜头被摊到好几行上，人一眼就看得出不对劲
  Future<List<UnitDraft>> _draftsOf(List<AsrSentence> sentences) async {
    if (splitter != null) {
      try {
        final drafts = await splitter!.split(sentences);
        if (drafts.isNotEmpty) return drafts;
        AppLog.warn('语义分组没给出单元，退回一句一行（行会偏碎）');
      } catch (e) {
        AppLog.warn('语义分组失败，退回一句一行（行会偏碎）：$e');
      }
    } else {
      AppLog.warn('没有语义分组能力（缺方舟凭据），退回一句一行（行会偏碎）');
    }
    return [
      for (final s in sentences)
        if (s.text.trim().isNotEmpty && s.endMs > s.startMs)
          UnitDraft(
              startMs: s.startMs, endMs: s.endMs, transcript: s.text.trim()),
    ];
  }

  Future<VideoInfo?> _info(String videoPath) async {
    try {
      return await probe.probe(videoPath);
    } catch (e) {
      AppLog.warn('参考片时长/帧率探测失败，末镜按最后一句台词收尾：$e');
      return null;
    }
  }

  int _lastSpokenMs(List<AsrSentence> sentences) =>
      sentences.fold<int>(0, (m, s) => s.endMs > m ? s.endMs : m);
}
