import 'dart:io';

import 'package:path/path.dart' as p;

import '../analysis/providers.dart' show AsrSentence, AsrWord;
import '../export/export_commands.dart';
import '../export/export_spec.dart';
import '../ffmpeg/process_runner.dart';
import '../subtitle/subtitle_overlay.dart';
import '../subtitle/subtitle_rasterizer.dart';
import '../subtitle/subtitle_style.dart';
import 'script_doc.dart';
import 'shot_allocation.dart';

/// 导出失败：message 面向用户，点名到行/镜头
class ScriptExportException implements Exception {
  final String message;
  final Object? cause;
  const ScriptExportException(this.message, {this.cause});
  @override
  String toString() => message;
}

/// 导出进度（等待要有交代：一段一报）
class ScriptExportProgress {
  final String step;
  final double fraction;
  const ScriptExportProgress(this.step, this.fraction);
}

/// 「脚本 → 成片」的导出编排：
///
/// 每镜渲一个规格化切片（框选起点 + 变速 + 字幕烧制）→ concat 视频；
/// 每行出一段音频（配音，画面行为静音）→ concat 音轨 → mux。
///
/// **交付拦截**（最高准则「不静默降级」）：任何一行没就绪（没配音、没镜头、
/// 没分配、素材不在本地）直接失败并点名——成片少一段是不允许的那类错，
/// 预览可以跳行，导出不行。
class ScriptExportRunner {
  final ProcessRunner run;
  final Directory workDir;
  final SubtitleRasterizer rasterizer;

  /// 已固定素材的本地路径（materialId → path）；null = 不在本地
  final String? Function(int materialId) localPathOf;

  /// 本地源镜头（参考段）的文件是否仍然存在
  final bool Function(String path) localSourceOk;

  ScriptExportRunner({
    required this.workDir,
    required this.localPathOf,
    bool Function(String path)? localSourceOk,
    this.run = systemProcessRunner,
    SubtitleRasterizer? rasterizer,
  })  : localSourceOk = localSourceOk ?? ((path) => File(path).existsSync()),
        rasterizer = rasterizer ?? SubtitleRasterizer(run: run);

  /// 导出一条成片到 [outPath]。返回实际输出路径。
  Future<String> export({
    required ScriptDoc doc,
    required String outPath,
    ExportSpec spec = ExportSpec.standard,
    SubtitleStyle? subtitleStyle,
    bool burnSubtitles = true,

    /// 整片配乐的本地路径。doc.bgm 非空却给不出本地文件时直接拦下——
    /// 成片悄悄少配乐不行
    String? bgmPath,
    void Function(ScriptExportProgress progress)? onProgress,
  }) async {
    final style = subtitleStyle ?? doc.subtitle;
    if (doc.bgm != null && bgmPath == null) {
      throw const ScriptExportException(
          '配乐还没下载到本地，导出被拦下（稍等下载完成或先取消配乐）。');
    }
    final lines = _readyLines(doc);
    if (lines.isEmpty) {
      throw const ScriptExportException('脚本里还没有可导出的行。');
    }
    await workDir.create(recursive: true);
    final videoParts = <String>[];
    final audioParts = <String>[];
    final totalShots =
        lines.fold(0, (a, e) => a + e.line.shots.length) + lines.length + 2;
    var done = 0;
    void tick(String step) =>
        onProgress?.call(ScriptExportProgress(step, ++done / totalShots));

    for (final entry in lines) {
      final line = entry.line;
      final lineIndex = entry.index;
      // 行的字幕（相对行起点的时间轴）；跨镜连续由逐镜裁剪自然形成
      final sentences = burnSubtitles ? _sentenceOf(line) : const <AsrSentence>[];
      var shotAtMs = 0;
      for (var j = 0; j < line.shots.length; j++) {
        final shot = line.shots[j];
        final String? src;
        if (shot.localSource != null) {
          src = localSourceOk(shot.localSource!) ? shot.localSource : null;
          if (src == null) {
            throw ScriptExportException(
                '第 ${lineIndex + 1} 行第 ${j + 1} 镜引用的参考视频已不在原位，导出被拦下。');
          }
        } else {
          src = localPathOf(shot.materialId);
          if (src == null) {
            throw ScriptExportException(
                '第 ${lineIndex + 1} 行第 ${j + 1} 镜的素材还没下载到本地，导出被拦下。');
          }
        }
        final allocMs = shot.allocMs!;
        final overlays = await _overlaysFor(
          sentences: sentences,
          slotStartMs: shotAtMs,
          slotEndMs: shotAtMs + allocMs,
          spec: spec,
          style: style,
        );
        final out = p.join(workDir.path, 'v_${lineIndex}_$j.mp4');
        await _exec(
          _shotVideoArgs(
            input: src,
            trimStartMs: shot.trimStartMs,
            allocMs: allocMs,
            speed: shot.speed,
            spec: spec,
            overlays: overlays,
            out: out,
          ),
          what: '第 ${lineIndex + 1} 行第 ${j + 1} 镜',
        );
        videoParts.add(out);
        shotAtMs += allocMs;
        tick('渲染第 ${lineIndex + 1} 行第 ${j + 1} 镜');
      }
      // 行音频：配音（截/补到行画面长），画面行为静音
      final lineSpanMs = shotAtMs;
      final audioOut = p.join(workDir.path, 'a_$lineIndex.wav');
      final vo = line.voiceover;
      if (line.type == ScriptLineType.voiced && vo != null) {
        await _exec([
          '-y', '-v', 'error',
          '-i', vo.audioPath,
          '-af', 'apad',
          '-t', _sec(lineSpanMs),
          '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s16le',
          audioOut,
        ], what: '第 ${lineIndex + 1} 行配音');
      } else {
        await _exec([
          '-y', '-v', 'error',
          '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
          '-t', _sec(lineSpanMs),
          '-c:a', 'pcm_s16le',
          audioOut,
        ], what: '第 ${lineIndex + 1} 行静音垫');
      }
      audioParts.add(audioOut);
      tick('铺第 ${lineIndex + 1} 行声音');
    }

    // 拼接与合流
    final videoConcat = p.join(workDir.path, 'video_all.mp4');
    final videoList = File(p.join(workDir.path, 'video.txt'))
      ..writeAsStringSync(ExportCommands.concatList(videoParts));
    await _exec(ExportCommands.concat(listFile: videoList.path, out: videoConcat),
        what: '拼接画面');
    tick('拼接画面');

    final audioConcat = p.join(workDir.path, 'audio_all.wav');
    final audioList = File(p.join(workDir.path, 'audio.txt'))
      ..writeAsStringSync(ExportCommands.concatList(audioParts));
    await _exec([
      '-y', '-v', 'error',
      '-f', 'concat', '-safe', '0', '-i', audioList.path,
      '-c', 'copy', audioConcat,
    ], what: '拼接声音');

    var finalAudio = audioConcat;
    if (doc.bgm != null && bgmPath != null) {
      final mixed = p.join(workDir.path, 'audio_bgm.wav');
      final totalMs = lines.fold(
          0,
          (a, e) =>
              a + e.line.shots.fold(0, (b, s) => b + (s.allocMs ?? 0)));
      await _exec(
          ExportCommands.mixBgm(
            voice: audioConcat,
            bgm: bgmPath,
            out: mixed,
            startMs: 0,
            durationMs: totalMs,
            bgmVolume: doc.bgmVolume,
          ),
          what: '混配乐');
      finalAudio = mixed;
    }

    await File(outPath).parent.create(recursive: true);
    await _exec(
        ExportCommands.mux(video: videoConcat, audio: finalAudio, out: outPath),
        what: '合成成片');
    tick('合成成片');
    return outPath;
  }

  /// 交付拦截：一行行验，问题点名到行。空行（无字无镜头）跳过
  List<({int index, ScriptLine line})> _readyLines(ScriptDoc doc) {
    final ready = <({int index, ScriptLine line})>[];
    final problems = <String>[];
    for (var i = 0; i < doc.lines.length; i++) {
      final line = doc.lines[i];
      if (line.text.trim().isEmpty && line.shots.isEmpty) continue;
      final root = ShotAllocation.rootMsOf(line);
      if (root == null) {
        problems.add(line.type == ScriptLineType.voiced
            ? '第 ${i + 1} 行还没生成配音'
            : '第 ${i + 1} 行还没确定时长');
        continue;
      }
      if (line.type == ScriptLineType.voiced &&
          line.voiceState == LineVoiceState.stale) {
        problems.add('第 ${i + 1} 行的台词改过了，配音还是旧的（重新生成后再导）');
        continue;
      }
      if (line.shots.isEmpty) {
        problems.add('第 ${i + 1} 行还没挑镜头');
        continue;
      }
      if (line.shots.any((s) => s.allocMs == null)) {
        problems.add('第 ${i + 1} 行的镜头还没分时长');
        continue;
      }
      ready.add((index: i, line: line));
    }
    if (problems.isNotEmpty) {
      throw ScriptExportException('导出被拦下：\n${problems.join('\n')}');
    }
    return ready;
  }

  /// 行配音的词级时间戳 → 字幕句（行文本兜底整句显示）
  List<AsrSentence> _sentenceOf(ScriptLine line) {
    final vo = line.voiceover;
    if (line.type != ScriptLineType.voiced || vo == null) return const [];
    return [
      AsrSentence(
        startMs: 0,
        endMs: vo.durationMs,
        text: vo.sourceText,
        words: [
          for (final w in vo.words)
            AsrWord(text: w.text, startMs: w.startMs, endMs: w.endMs),
        ],
      ),
    ];
  }

  Future<List<SubtitleOverlayImage>> _overlaysFor({
    required List<AsrSentence> sentences,
    required int slotStartMs,
    required int slotEndMs,
    required ExportSpec spec,
    required SubtitleStyle style,
  }) async {
    if (sentences.isEmpty) return const [];
    final lines = subtitleLinesInSlot(
        sentences: sentences, slotStartMs: slotStartMs, slotEndMs: slotEndMs);
    return rasterizer.rasterize(
      lines: lines,
      width: spec.width,
      height: spec.height,
      style: style,
      outDir: Directory(p.join(workDir.path, 'subtitles')),
    );
  }

  /// 一个镜头的规格化切片：框选起点 + 变速 + 统一规格 + 字幕叠加 +
  /// 精确帧数（scale/pad 与 ExportCommands 同一套口径）
  List<String> _shotVideoArgs({
    required String input,
    required int trimStartMs,
    required int allocMs,
    required double speed,
    required ExportSpec spec,
    required List<SubtitleOverlayImage> overlays,
    required String out,
  }) {
    final scalePad = 'scale=${spec.width}:${spec.height}'
        ':force_original_aspect_ratio=decrease,'
        'pad=${spec.width}:${spec.height}:(ow-iw)/2:(oh-ih)/2:black,setsar=1';
    final speedFilter =
        (speed - 1).abs() < 1e-6 ? '' : ',setpts=PTS/$speed';
    final baseChain =
        '$scalePad$speedFilter,tpad=stop_mode=clone:stop_duration=${_sec(allocMs)}';
    return [
      '-y', '-v', 'error',
      '-ss', _sec(trimStartMs),
      '-t', _sec((allocMs * speed).round()),
      '-i', input,
      for (final o in overlays) ...['-i', o.pngPath],
      '-an',
      if (overlays.isEmpty) ...[
        '-vf', baseChain,
      ] else ...[
        '-filter_complex',
        subtitleFilterComplex(baseChain: baseChain, overlays: overlays),
        '-map', subtitleFilterOutLabel(overlays.length),
      ],
      '-r', '${spec.fps}',
      ...spec.encodeArgs,
      '-pix_fmt', 'yuv420p',
      '-frames:v', '${ExportCommands.frameCount(allocMs, atFps: spec.fps.toDouble())}',
      out,
    ];
  }

  Future<void> _exec(List<String> args, {required String what}) async {
    final result = await run('ffmpeg', args);
    if (result.exitCode != 0) {
      throw ScriptExportException('$what渲染失败（ffmpeg exit=${result.exitCode}）',
          cause: result.stderr);
    }
  }

  static String _sec(int ms) => (ms / 1000).toStringAsFixed(3);
}
