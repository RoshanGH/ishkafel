import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/subtitle_view.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/time/rational.dart';

/// 报告的三条规矩（spec §5）：
/// 1. 对外只出帧，不出毫秒
/// 2. 位置一律是成片帧轴上的绝对帧
/// 3. 「听到什么」和「显示什么」分成两块字段，永不混写
void main() {
  RenewTask task() => RenewTask(
        id: 't1', name: '测试', status: RenewTaskStatus.ready,
        createdAt: DateTime(2026, 9, 20), updatedAt: DateTime(2026, 9, 20),
        videoInfo: VideoInfo(
            width: 1080, height: 1920, fps: 30,
            duration: const Duration(milliseconds: 2000),
            fpsExact: Rational.fps30,
            fileSizeBytes: 0),
        asrSentences: const [
          AsrSentence(startMs: 0, endMs: 900, text: '甲乙', words: [
            AsrWord(startMs: 0, endMs: 400, text: '甲'),
            AsrWord(startMs: 400, endMs: 900, text: '乙'),
          ]),
        ],
        units: const [
          SemanticUnit(
            uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '甲乙',
            shots: [
              Shot(startMs: 0, endMs: 1000),
              Shot(startMs: 1000, endMs: 2000),
            ],
          ),
        ],
      );

  test('全片：一镜一行，带位置、听到什么、显示什么', () {
    final r = subtitleReport(task());
    final rows = r['shots'] as List;
    expect(rows, hasLength(2));
    final first = rows.first as Map<String, dynamic>;
    expect(first['at'], 'U1S1');
    expect(first['frames'], isA<List<int>>());
    expect(first.containsKey('heard'), isTrue, reason: '听到什么');
    expect(first.containsKey('lines'), isTrue, reason: '显示什么');
  });

  test('对外只出帧，报告里不许出现毫秒字段', () {
    final json = subtitleReport(task()).toString();
    expect(json.contains('Ms'), isFalse,
        reason: '两套数字并存就一定有人对错——毫秒退回存储格式');
  });

  test('帧率来路要说清', () {
    expect(subtitleReport(task())['fpsSource'], 'original');
  });

  test('单镜：带相邻镜的字幕，判断串字必须看得到隔壁', () {
    final r = subtitleShotReport(task(), unitIndex: 0, shotIndex: 1)!;
    expect((r['neighbours'] as Map)['prev'], isNotNull);
    expect(r['voice'], isA<Map>());
    expect((r['voice'] as Map)['source'], 'original');
  });

  test('越界返回 null，不抛', () {
    expect(subtitleShotReport(task(), unitIndex: 9, shotIndex: 0), isNull);
  });
}
