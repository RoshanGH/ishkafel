// 端到端集成冒烟测试（真凭据、真实网络、真实 ffmpeg）
//
// 运行方式：
//   flutter test test/integration --tags integration --run-skipped
//
// 说明：dart_test.yaml 中把 integration 标签配置为默认 skip——test 包的规则是
// 「tag 级 skip 配置优先于 --tags 选择器」，仅传 --tags integration 并不会强制
// 执行（会显示为 Skip），必须额外加 --run-skipped 才能真正跑。默认
// `flutter test`（不带任何参数）不受影响，本文件会按配置被跳过，不产生真实
// 网络调用。
//
// 前置条件（任一不满足则整体 skip，不判失败）：
//   - 项目根目录 .secrets/ 下 ark_api_key / speech_app_id / speech_access_token
//     三份凭据齐全（CredentialsLoader 读取，需在项目根目录下执行）
//   - 本机存在测试视频（见下方 _videoPath，硬编码路径仅本机可跑，属预期行为）
//   - PATH 中存在真实可执行的 ffmpeg / ffprobe
//
// 覆盖链路：AudioExtractor 提取 PCM → VolcanoAsrProvider 真实识别（校验句子
// 非空、文本命中关键词、字级时间戳存在且落在句子区间内）→
// VolcanoSemanticSplitter 真实语义分组（校验单元数量与无缝覆盖）→
// SceneDetector 真实场景检测（校验边界数）→ SegmentationBuilder 构树（校验
// 严格嵌套与帧对齐）。耗时约 1-2 分钟，会产生真实计费调用，仅供本机手动验证。
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_credentials.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/ai/volcano_asr_provider.dart';
import 'package:ishkafel/core/ai/volcano_semantic_splitter.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/boundary_snapper.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/ffmpeg/ffprobe_service.dart';

const _videoPath = '/Users/menggang/Documents/滴露视频/'
    'JC_滴露_植源喷雾_XCT_SQ1&YY6_CH_千川直播_M66028501_0427.mp4';

void main() {
  final creds = CredentialsLoader.load(secretsDirs: [Directory('.secrets')]);
  final videoExists = File(_videoPath).existsSync();
  final ffmpegReady = _checkExecutable('ffmpeg') && _checkExecutable('ffprobe');

  final String? skipReason = !creds.isComplete
      ? '真实凭据不完整（.secrets 缺 ark_api_key/speech_app_id/speech_access_token 之一）'
      : !videoExists
          ? '测试视频不存在：$_videoPath'
          : !ffmpegReady
              ? 'PATH 中找不到可执行的 ffmpeg/ffprobe'
              : null;

  group('端到端集成冒烟（真凭据）', () {
    test(
      'AudioExtractor→VolcanoAsr→VolcanoSemanticSplitter→SceneDetector→SegmentationBuilder 全链路',
      () async {
        final tempDir =
            await Directory.systemTemp.createTemp('ishkafel_integration_');
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final pcmPath = '${tempDir.path}/audio.pcm';

        // 1. 真实 ffmpeg 提取音频 PCM
        await AudioExtractor().extractSamples(
          videoPath: _videoPath,
          outPcmPath: pcmPath,
        );

        // 2. 真实火山 ASR 识别
        final asr = VolcanoAsrProvider(
          appId: creds.speechAppId,
          accessToken: creds.speechAccessToken,
        );
        final sentences = await asr.transcribe(pcmPath);

        expect(sentences, isNotEmpty, reason: 'ASR 识别结果不应为空');
        final fullText = sentences.map((s) => s.text).join();
        expect(
          fullText.contains('滴露') || fullText.contains('喷雾'),
          isTrue,
          reason: 'ASR 文本应命中「滴露」或「喷雾」，实际：$fullText',
        );

        // 字级时间戳：至少一条句子的 words 非空，且每个字都落在句子区间内
        final sentenceWithWords =
            sentences.where((s) => s.words.isNotEmpty).toList();
        expect(
          sentenceWithWords,
          isNotEmpty,
          reason: '应至少有一条句子返回字级时间戳（words 非空）',
        );
        for (final sentence in sentenceWithWords) {
          for (final word in sentence.words) {
            expect(word.startMs, greaterThanOrEqualTo(sentence.startMs),
                reason: '字级时间戳应落在句子区间内');
            expect(word.endMs, lessThanOrEqualTo(sentence.endMs),
                reason: '字级时间戳应落在句子区间内');
          }
        }

        // 3. 真实火山方舟 LLM 语义分组
        final splitter = VolcanoSemanticSplitter(
          chat: ArkChatClient(apiKey: creds.arkApiKey),
        );
        final drafts = await splitter.split(sentences);

        expect(drafts.length, inInclusiveRange(2, 20),
            reason: '语义单元数应在 2-20 之间，实际：${drafts.length}');
        // 无缝覆盖：所有单元台词拼接应与全部句子拼接一致（不漏句、不重句）
        expect(drafts.map((d) => d.transcript).join(), fullText,
            reason: '语义单元应无缝覆盖全部句子，不丢句也不重复');
        // 单元在时间轴上顺序不重叠
        for (var i = 0; i < drafts.length - 1; i++) {
          expect(drafts[i].endMs, lessThanOrEqualTo(drafts[i + 1].startMs),
              reason: '相邻语义单元不应在时间轴上重叠');
        }

        // 4. 真实 ffmpeg 场景检测
        final shotBoundaries = await SceneDetector().detect(_videoPath);
        expect(shotBoundaries.length, greaterThan(3),
            reason: '镜头边界数应大于 3，实际：${shotBoundaries.length}');

        // 5. 真实 ffprobe 视频元信息 + 构树
        final info = await FfprobeService().probe(_videoPath);
        final builder = SegmentationBuilder();
        final units = builder.build(
          drafts: drafts,
          shotBoundaryMs: shotBoundaries,
          silenceValleyMs: const [],
          videoDurationMs: info.duration.inMilliseconds,
          fps: info.fps,
        );

        expect(units.length, drafts.length);
        expect(units.first.startMs, 0, reason: '首单元边界恒为 0');
        expect(units.last.endMs, info.duration.inMilliseconds,
            reason: '尾单元边界恒为片长');

        const snapper = BoundarySnapper();
        for (var i = 0; i < units.length; i++) {
          final unit = units[i];
          // 严格包含：单元内所有镜头必须落在单元范围内
          expect(unit.shotsStrictlyNested, isTrue,
              reason: '单元 $i 的镜头必须严格嵌套在单元区间内');
          // 无缝覆盖：与下一单元首尾相接
          if (i < units.length - 1) {
            expect(unit.endMs, units[i + 1].startMs,
                reason: '单元 $i 与下一单元应无缝衔接');
          }
          // 帧对齐：单元边界经吸附后应保持不变（即已是帧对齐值）
          expect(snapper.snapToFrame(unit.startMs, info.fps), unit.startMs,
              reason: '单元 $i 起始边界应帧对齐');
          expect(snapper.snapToFrame(unit.endMs, info.fps), unit.endMs,
              reason: '单元 $i 结束边界应帧对齐');
          // 单元内镜头无缝覆盖单元且帧对齐
          expect(unit.shots.first.startMs, unit.startMs);
          expect(unit.shots.last.endMs, unit.endMs);
          for (var k = 0; k < unit.shots.length; k++) {
            final shot = unit.shots[k];
            expect(snapper.snapToFrame(shot.startMs, info.fps), shot.startMs,
                reason: '单元 $i 镜头 $k 起始边界应帧对齐');
            expect(snapper.snapToFrame(shot.endMs, info.fps), shot.endMs,
                reason: '单元 $i 镜头 $k 结束边界应帧对齐');
            if (k < unit.shots.length - 1) {
              expect(shot.endMs, unit.shots[k + 1].startMs,
                  reason: '单元 $i 内相邻镜头应无缝衔接');
            }
          }
        }
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

/// 检测可执行文件是否真实存在于 PATH 中（跨平台用 which/where 均可，这里只用 which，
/// 项目目标平台为 macOS/Linux 桌面）
bool _checkExecutable(String name) {
  try {
    final result = Process.runSync('which', [name]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
