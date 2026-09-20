import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/subtitle_view.dart';
import 'package:ishkafel/core/ai/frame_check.dart';
import 'package:ishkafel/core/ai/frame_check_wiring.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_track.dart';
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

  // 整体替换选了候选，但那条候选还没探出时长——ComposedTimeline 会静默退回
  // 原片坑位的长度，那个单元之后每一段的成片起点都跟着错，报出去的帧号
  // 看着精确却会在 candidates fetch 之后整体平移。跟 task_view.dart 的
  // composedUnavailable 是同一条判据，这里不能各写各的
  RenewTask taskWithUnknownWholeDuration() => RenewTask(
        id: 't2', name: '测试2', status: RenewTaskStatus.ready,
        createdAt: DateTime(2026, 9, 20), updatedAt: DateTime(2026, 9, 20),
        videoInfo: VideoInfo(
            width: 1080, height: 1920, fps: 30,
            duration: const Duration(milliseconds: 2000),
            fpsExact: Rational.fps30,
            fileSizeBytes: 0),
        units: const [
          SemanticUnit(
            uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '甲乙',
            shots: [
              Shot(startMs: 0, endMs: 1000),
              Shot(startMs: 1000, endMs: 2000),
            ],
          ),
        ],
        replacementsByUid: {
          'u0': UnitReplacement.whole(const [1]),
        },
        // 挑了候选（id 1），但这条素材没有 durationMs——时长还没探出来
        pickedMaterials: const [PickedMaterial(id: 1, name: '候选')],
      );

  test('整体替换的素材时长还没探出来：整块拒答并点名，不给会变的帧号', () {
    final r = subtitleReport(taskWithUnknownWholeDuration());
    expect(r.containsKey('shots'), isFalse,
        reason: '那个单元之后每一段的成片起点都是错的，帧号会在 fetch 之后整体平移');
    expect(r['framesUnavailable'], contains('candidates fetch'),
        reason: '要给一条能照做的补救命令，不能只说「算不出来」');
  });

  test('单镜同理：拒答要跟「这个下标不存在」分得开', () {
    final r = subtitleShotReport(taskWithUnknownWholeDuration(),
        unitIndex: 0, shotIndex: 0);
    expect(r, isNotNull, reason: 'null 的含义是下标不存在，别拿它兼作「算不准」');
    expect(r!.containsKey('framesUnavailable'), isTrue);
  });

  // 整体替换、候选时长已知（避开上面那个「framesUnavailable」分支）——这时
  // 那个单元是真正的整块（ComposedTimeline.isSolidBlock），shotSpan 为
  // null。它的镜头不许从报告里消失：voiceSourceOf 会把它报成 replaced，
  // Agent 得看得见这段存在过，只是给不了精确帧位置
  RenewTask taskWithSolidBlockUnit() => RenewTask(
        id: 't3', name: '测试3', status: RenewTaskStatus.ready,
        createdAt: DateTime(2026, 9, 20), updatedAt: DateTime(2026, 9, 20),
        videoInfo: VideoInfo(
            width: 1080, height: 1920, fps: 30,
            duration: const Duration(milliseconds: 2000),
            fpsExact: Rational.fps30,
            fileSizeBytes: 0),
        units: const [
          SemanticUnit(
            uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '甲乙',
            shots: [
              Shot(startMs: 0, endMs: 1000),
              Shot(startMs: 1000, endMs: 2000),
            ],
          ),
        ],
        replacementsByUid: {
          'u0': UnitReplacement.whole(const [1]),
        },
        // 候选时长已知，且跟原坑位不等——真正的整块替换
        pickedMaterials: const [
          PickedMaterial(id: 1, name: '候选', durationMs: 1500),
        ],
      );

  test('整体替换的镜头照样出现在报告里，只是没有帧位置', () {
    final rows = subtitleReport(taskWithSolidBlockUnit())['shots'] as List;
    final row =
        rows.firstWhere((r) => (r as Map)['at'] == 'U1S1') as Map;
    expect(row['voice'], 'replaced',
        reason: '整段消失的话，Agent 连这段存在过都不知道');
    expect(row.containsKey('frames'), isFalse,
        reason: '给不了精确帧位置就整个字段不出现，不编一个');
  });

  test('单镜：落在整块上的合法下标，不许跟「下标不存在」共用 null', () {
    final r = subtitleShotReport(taskWithSolidBlockUnit(),
        unitIndex: 0, shotIndex: 0);
    expect(r, isNotNull, reason: 'null 的含义是这个下标不存在');
    expect((r!['voice'] as Map)['source'], 'replaced');
    expect(r.containsKey('frames'), isFalse);
  });

  test('整块段落上，行的帧号也不许编', () {
    // 给 U1S1 的字幕轨手改上一行内容——文本是真的（要报），但镜头偏移量的
    // 是原片，那一段在成片里的长度跟着素材走，偏移根本不成立（帧号不能编）
    final track = const SubtitleTrack.empty().withLines(
      const SubtitleSlot(unitUid: 'u0', shotIndex: 0),
      const [SubtitleLine(startMs: 0, endMs: 500, text: '手改的字')],
    );
    final task = taskWithSolidBlockUnit().copyWith(subtitleTrack: track);
    final r = subtitleShotReport(task, unitIndex: 0, shotIndex: 0)!;
    final lines = r['lines'] as List;
    expect(lines, isNotEmpty, reason: '手改过，文本是真的，要报');
    expect((lines.first as Map).containsKey('frames'), isFalse,
        reason: '镜头偏移量的是原片，在成片里不成立——跟 shot 级同一条纪律');
  });

  test('单镜报告带上 caption：字幕落在画面哪个矩形，纯计算', () {
    final r = subtitleShotReport(task(), unitIndex: 0, shotIndex: 0)!;
    final caption = r['caption'] as Map;
    expect(caption['maxCharsPerScreen'], isA<int>());
    expect(caption['willWrap'], isA<bool>());
    final box = caption['box'] as Map;
    expect(box['left'], lessThan(box['right']));
  });

  test('没给 dataDir 就没查烧字，报告里整个不出现 burned 字段', () {
    final r = subtitleShotReport(task(), unitIndex: 0, shotIndex: 0)!;
    expect(r.containsKey('burned'), isFalse,
        reason: '没查等于没查，不能报一个空数组假装查过');
  });

  // 镜头级替换选中了候选 id 7——burned 要从这条候选的画面自查缓存里查
  RenewTask taskWithShotCandidate() => RenewTask(
        id: 't4', name: '测试4', status: RenewTaskStatus.ready,
        createdAt: DateTime(2026, 9, 20), updatedAt: DateTime(2026, 9, 20),
        videoInfo: VideoInfo(
            width: 1080, height: 1920, fps: 30,
            duration: const Duration(milliseconds: 2000),
            fpsExact: Rational.fps30,
            fileSizeBytes: 0),
        units: const [
          SemanticUnit(
            uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '甲乙',
            shots: [
              Shot(startMs: 0, endMs: 1000),
              Shot(startMs: 1000, endMs: 2000),
            ],
          ),
        ],
        replacementsByUid: {
          'u0': UnitReplacement.perShot({0: const [7]}),
        },
      );

  test('给了 dataDir、这一镜的候选也被看过：报出烧字（可以是空数组）', () {
    final dataDir =
        Directory.systemTemp.createTempSync('subtitle_view_test_');
    addTearDown(() => dataDir.deleteSync(recursive: true));
    frameCheckCacheIn(dataDir)
        .put(7, const FrameCheck(burnedText: ['冰冰凉凉的好舒服呀']));

    final r = subtitleShotReport(taskWithShotCandidate(),
        unitIndex: 0, shotIndex: 0, dataDir: dataDir)!;
    expect(r['burned'], ['冰冰凉凉的好舒服呀']);
  });

  test('给了 dataDir，但这条候选还没被看过：没查过，不报字段', () {
    final dataDir =
        Directory.systemTemp.createTempSync('subtitle_view_test_');
    addTearDown(() => dataDir.deleteSync(recursive: true));

    final r = subtitleShotReport(taskWithShotCandidate(),
        unitIndex: 0, shotIndex: 0, dataDir: dataDir)!;
    expect(r.containsKey('burned'), isFalse);
  });

  test('给了 dataDir，但这一镜没有替换候选：没什么可查，不报字段', () {
    final dataDir =
        Directory.systemTemp.createTempSync('subtitle_view_test_');
    addTearDown(() => dataDir.deleteSync(recursive: true));

    final r = subtitleShotReport(task(), unitIndex: 0, shotIndex: 0,
        dataDir: dataDir)!;
    expect(r.containsKey('burned'), isFalse);
  });
}
