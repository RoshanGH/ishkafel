import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../analysis/providers.dart';
import '../audio/delivery_analyzer.dart';
import '../audio/prosody_profile.dart';
import '../log/app_log.dart';
import 'script_doc.dart';

/// 一行「该怎么念」的结论。
///
/// [instruction] 为空有两种意思，靠 [degradedReason] 区分：本来就没有参考片
/// （手写脚本，不算降级），还是听了但没听成（降级，必须说出来）。
class LineDelivery {
  /// 直接喂给 TTS 的 `context_texts`。空 = 不带指令
  final String instruction;

  /// 非 null = 这一句本来该带指令、结果没带上，以及为什么。
  /// **不许咽下去**：情绪扁平的成片和正常成片肉眼分不出来，
  /// 不说的话人只会觉得「这软件配出来就是这个味儿」
  final String? degradedReason;

  /// 这次是吃的缓存还是真花钱算的（报给人看，也用来验「没重复花钱」）
  final bool cached;

  const LineDelivery({
    required this.instruction,
    this.degradedReason,
    this.cached = false,
  });

  /// 没有参考可听——照旧不带指令，不是降级
  static const none = LineDelivery(instruction: '');

  bool get hasInstruction => instruction.trim().isNotEmpty;
}

/// 要听参考片的哪一段、听的是哪句话。
///
/// 单独立一个请求对象是为了把「从 ScriptDoc 里挑出这些」和「听 + 缓存」
/// 分开：前者纯计算好测，后者要切片要调模型
class LineDeliveryRequest {
  final String lineId;

  /// 脚本里的这句台词（**不是**参考片 ASR 出来的那句）——指令是给这句话用的
  final String transcript;

  final String videoPath;
  final int startMs;
  final int endMs;

  /// 从参考片词级时间戳量出来的语速/停顿/被拖长的字。
  /// 模型光听容易顺着台词内容脑补，把客观测量一并递上去它才落在这段录音上
  final ProsodyProfile? prosody;

  const LineDeliveryRequest({
    required this.lineId,
    required this.transcript,
    required this.videoPath,
    required this.startMs,
    required this.endMs,
    this.prosody,
  });

  /// 内容指纹：参考片 + 区间 + 台词。
  /// **按内容而不是按行 id**——行 id 一辈子不变，台词改了还吃缓存的话，
  /// 放出来的是上一版台词的念法
  String get fingerprint => sha1
      .convert(utf8.encode('$videoPath|$startMs|$endMs|${transcript.trim()}'))
      .toString();
}

/// 这一行有没有可听的参考。null = 没有，照旧不带指令合成。
///
/// 三种「没有」：手写脚本（行上根本没有 reference）、参考片路径缺失、
/// 行上传的是一张图（图没有声音，那段区间也不是文档级参考片里的坐标）
LineDeliveryRequest? deliveryRequestOf(ScriptDoc doc, ScriptLine line) {
  final ref = line.reference;
  if (ref == null || ref.durationMs <= 0) return null;
  if (ref.videoPath == null && ref.imagePath != null) return null;
  final video = doc.refVideoOf(line);
  if (video == null || video.isEmpty) return null;
  final transcript = line.text.trim();
  if (transcript.isEmpty) return null;
  return LineDeliveryRequest(
    lineId: line.id,
    transcript: transcript,
    videoPath: video,
    startMs: ref.startMs,
    endMs: ref.endMs,
    prosody: ProsodyProfile.measure(
      words: [
        for (final w in ref.words)
          AsrWord(startMs: w.startMs, endMs: w.endMs, text: w.text),
      ],
      referenceCharsPerSec: _referenceCharsPerSec(doc),
    ),
  );
}

/// 全片平均语速，用来判断某一句是偏快还是偏慢（没有它 Pace 只会是「正常」）
double _referenceCharsPerSec(ScriptDoc doc) {
  var chars = 0;
  var ms = 0;
  for (final line in doc.lines) {
    final ref = line.reference;
    if (ref == null || ref.durationMs <= 0 || ref.words.isEmpty) continue;
    chars += ref.words.length;
    ms += ref.durationMs;
  }
  return ms > 0 ? chars * 1000 / ms : 0;
}

/// 「参考片这一句是怎么念的」——切出来、听一遍、把结论缓存住。
///
/// 为什么脚本成片需要它：这条线用的是预置音色（不克隆原声），不带指令的话
/// 每句都是模型的默认语气。原片那个人激动地在争吵，复刻出来平铺直叙——
/// 用户第一句反馈就是这个。分析这层替换裂变的换音色一直在用
/// （voice_swap_service），这里是把同一套东西接到脚本成片上。
class LineDeliveryService {
  final DeliveryAnalyzer analyzer;

  /// 从参考片切出 `[startMs, endMs)` 的 16k 单声道 WAV。注入而不是内建
  /// ffmpeg 调用：这一层要能在不碰真实进程的情况下测
  final Future<List<int>> Function(String videoPath, int startMs, int endMs)
      slice;

  /// 分析结论落这儿（按内容指纹命名）。放在任务自己的目录下，
  /// 删任务时随目录清走，不留孤儿
  final Directory cacheDir;

  /// 降级过的行：lineId → 原因。跑完由调用方一次说清楚，
  /// 而不是每句都刷一行日志让人自己数
  final Map<String, String> degraded = {};

  LineDeliveryService({
    required this.analyzer,
    required this.slice,
    required this.cacheDir,
  });

  Future<LineDelivery> resolve(LineDeliveryRequest? request) async {
    if (request == null) return LineDelivery.none;
    final cached = _readCache(request);
    if (cached != null) {
      return LineDelivery(instruction: cached, cached: true);
    }
    try {
      final wav = await slice(request.videoPath, request.startMs, request.endMs);
      final analysis = await analyzer.analyze(
        audioWav: wav,
        transcript: request.transcript,
        prosody: request.prosody,
      );
      // 空指令也落盘：那是一次已经花过钱的完整调用，重配时再听一遍
      // 只会再花一次钱、拿到同样的空
      _writeCache(request, analysis);
      return LineDelivery(instruction: analysis.instruction.trim());
    } catch (e) {
      // 听不了不等于配不了音——退回默认语气，但这句必须点名，
      // 否则人只会看到「有几句情绪不对」却不知道是哪几句、为什么
      final reason = '$e';
      degraded[request.lineId] = reason;
      AppLog.warn('参考片这一句听不了，改用默认语气配音'
          '（line=${request.lineId}）：$reason');
      return LineDelivery(instruction: '', degradedReason: reason);
    }
  }

  File _cacheFile(LineDeliveryRequest request) =>
      File(p.join(cacheDir.path, 'delivery_${request.fingerprint}.json'));

  /// 读缓存。读坏了当没有——一份坏 JSON 不该让整句配音走不下去
  String? _readCache(LineDeliveryRequest request) {
    final file = _cacheFile(request);
    if (!file.existsSync()) return null;
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return null;
      final instruction = raw['instruction'];
      return instruction is String ? instruction.trim() : null;
    } catch (e) {
      AppLog.warn('念法缓存读不出来，重新分析（${file.path}）：$e');
      return null;
    }
  }

  void _writeCache(LineDeliveryRequest request, DeliveryAnalysis analysis) {
    try {
      cacheDir.createSync(recursive: true);
      _cacheFile(request).writeAsStringSync(jsonEncode({
        'instruction': analysis.instruction.trim(),
        'description': analysis.description,
        // 指纹是哈希，看不出是哪句话。留一份原文，出问题时能对上
        'transcript': request.transcript,
        'videoPath': request.videoPath,
        'startMs': request.startMs,
        'endMs': request.endMs,
      }));
    } catch (e) {
      // 写不进去只是下次要重花一次钱，不该让这一句配音失败
      AppLog.warn('念法缓存写不进去（line=${request.lineId}）：$e');
    }
  }
}
