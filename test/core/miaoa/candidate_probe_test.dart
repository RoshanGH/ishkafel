import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/candidate_probe.dart';

/// 真实 ffprobe 对候选素材签名 URL 的输出（`-of default=nw=1`）
const _realOutput = '''
width=1920
height=1080
duration=6.138333
''';

void main() {
  group('候选素材规格探测（miaoa 不返回 duration/resolution，只能自己探）', () {
    test('解析真实 ffprobe 输出', () {
      final spec = CandidateProbe.parseFfprobeOutput(_realOutput);
      expect(spec, isNotNull);
      expect(spec!.width, 1920);
      expect(spec.height, 1080);
      expect(spec.durationMs, 6138);
    });

    test('字段缺失返回 null，而不是用 0 冒充', () {
      expect(CandidateProbe.parseFfprobeOutput('width=1920\nheight=1080\n'), isNull,
          reason: '缺 duration 时若返回 0，时长差会算成「差 100%」，'
              '候选卡会挂上一个凭空捏造的红色警告');
      expect(CandidateProbe.parseFfprobeOutput('duration=N/A\n'), isNull);
      expect(CandidateProbe.parseFfprobeOutput(''), isNull);
    });

    test('零值与负值视为非法', () {
      expect(
          CandidateProbe.parseFfprobeOutput('width=0\nheight=1080\nduration=6'),
          isNull);
      expect(
          CandidateProbe.parseFfprobeOutput(
              'width=1920\nheight=1080\nduration=0'),
          isNull);
    });

    test('同一素材只探测一次（翻页/切换检索模式会反复看到同一条）', () async {
      var calls = 0;
      final probe = CandidateProbe(run: (_, args) async {
        calls++;
        return ProcessResult(1, 0, _realOutput, '');
      });

      await probe.probe(materialId: 1, previewUrl: 'https://cdn/x.mov');
      await probe.probe(materialId: 1, previewUrl: 'https://cdn/x.mov');

      expect(calls, 1);
      expect(probe.cached(1)?.durationMs, 6138);
    });

    test('探测失败返回 null 且不抛，不阻断整个候选面板', () async {
      final failing = CandidateProbe(run: (_, args) async =>
          ProcessResult(1, 1, '', 'Server returned 403 Forbidden'));
      final throwing =
          CandidateProbe(run: (_, args) async => throw const SocketException('断网'));

      expect(await failing.probe(materialId: 1, previewUrl: 'https://cdn/x.mov'),
          isNull);
      expect(await throwing.probe(materialId: 2, previewUrl: 'https://cdn/x.mov'),
          isNull,
          reason: '候选面板一次展示二十条，任何一条探测失败都不该让整个面板报错');
    });

    test('没有预览地址时不发起探测', () async {
      var calls = 0;
      final probe = CandidateProbe(run: (_, args) async {
        calls++;
        return ProcessResult(1, 0, _realOutput, '');
      });

      expect(await probe.probe(materialId: 1, previewUrl: null), isNull);
      expect(await probe.probe(materialId: 2, previewUrl: ''), isNull);
      expect(calls, 0);
    });
  });

  group('时长匹配判定（产品已定 ±15% 容忍度）', () {
    test('容忍度内判为可变速对齐', () {
      expect(judgeDurationFit(candidateMs: 6000, targetMs: 6000),
          DurationFit.within);
      expect(judgeDurationFit(candidateMs: 6800, targetMs: 6000),
          DurationFit.within, reason: '+13.3% 在 15% 以内');
      expect(judgeDurationFit(candidateMs: 5200, targetMs: 6000),
          DurationFit.within, reason: '-13.3% 在 15% 以内');
    });

    test('边界正好 15% 算容忍内（不把临界值判为超限）', () {
      expect(judgeDurationFit(candidateMs: 6900, targetMs: 6000),
          DurationFit.within);
      expect(judgeDurationFit(candidateMs: 5100, targetMs: 6000),
          DurationFit.within);
    });

    test('超限区分过长与过短（两者的兜底策略完全不同）', () {
      expect(judgeDurationFit(candidateMs: 9000, targetMs: 6000),
          DurationFit.tooLong, reason: '过长：变速到上限后裁尾保头');
      expect(judgeDurationFit(candidateMs: 3000, targetMs: 6000),
          DurationFit.tooShort, reason: '过短：慢放 + 末帧定格，且列表排后');
    });

    test('容忍度可调（产品说明「±15%，设置可调」）', () {
      expect(
          judgeDurationFit(candidateMs: 7000, targetMs: 6000, tolerance: 0.05),
          DurationFit.tooLong);
      expect(
          judgeDurationFit(candidateMs: 7000, targetMs: 6000, tolerance: 0.3),
          DurationFit.within);
    });

    test('目标时长非法时不产生假警告', () {
      expect(judgeDurationFit(candidateMs: 6000, targetMs: 0),
          DurationFit.within);
    });
  });
}
