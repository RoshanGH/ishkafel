import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/subtitle_view.dart';
import 'package:ishkafel/cli/task_view.dart' show wholeDurationsOf;
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
import 'package:ishkafel/core/subtitle/subtitle_style.dart';
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

  /// **这条线上已经栽过三次「三态混成两态」。**
  ///
  /// `subtitleSignal` 把三态分开了（还没分析 / 算不准 / 数得出来），
  /// 而 `subtitleReport` 只有两态：`units == null` 时返回
  /// `{projectFps, fpsSource, totalFrames: 0, shots: []}`——和「分析完了、
  /// 确实一个镜头都没有」一模一样。而信号的 note 正是「分析完再来看：
  /// ishkafel subtitle show <任务>」，Agent 照着敲过去，拿到的是一份
  /// 看不出区别的空报告
  RenewTask taskNotAnalyzed() => RenewTask(
        id: 't7', name: '测试7', status: RenewTaskStatus.ready,
        createdAt: DateTime(2026, 9, 20), updatedAt: DateTime(2026, 9, 20),
      );

  test('还没分析的任务：给一句实话，不拿空数组顶', () {
    final r = subtitleReport(taskNotAnalyzed());
    expect(r.containsKey('shots'), isFalse,
        reason: '空的 shots 和「分析完了、确实没有镜头」分不开');
    expect(r['notAnalyzed'], isA<String>());
    expect(r['notAnalyzed'], contains('analyze'),
        reason: '要给一条能照做的去处，不能只说「没有」');
  });

  test('单镜同理：还没分析跟「这个下标不存在」不能共用 null', () {
    final r = subtitleShotReport(taskNotAnalyzed(), unitIndex: 0, shotIndex: 0);
    expect(r, isNotNull,
        reason: 'null 的含义是这个下标不存在——还没分析时根本谈不上下标对不对');
    expect(r!.containsKey('notAnalyzed'), isTrue);
  });

  /// `taskToJson` 已经算过一次 `wholeDurationsOf` 了，`subtitleSignal` 里面
  /// 再算一次是白算——而 `wholeDurationsOf` 头上明写「这个算法全项目只许有
  /// 这一处」。传进来的那份和自己算的那份必须是同一个答案，否则这个入参
  /// 就成了一条能悄悄给出不同结论的旁路
  test('调用方算好的 wholeDurations 传进来，结论不变', () {
    final t = task();
    expect(subtitleSignal(t, whole: wholeDurationsOf(t)), subtitleSignal(t));
  });

  test('task_view 要真把算好的那份传下来，不然这个入参形同虚设', () {
    final src = File('lib/cli/task_view.dart').readAsStringSync();
    expect(src.contains('subtitleSignal(task, whole:'), isTrue,
        reason: 'taskToJson 里 wholeDurationsOf 算过一次了，'
            '不传下来就等于白加这个入参');
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

  /// 报告里「相邻两行不共享任何一帧」这句话，以前只写在注释里没人守——
  /// `_lineRow` 裸调 `FrameSpan.fromMs`，段头是直接四舍五入的，边界毫秒的
  /// 小数部分小于 0.5 时前一行的末帧和后一行的首帧就是同一帧。真机任务 #1
  /// 的 11 对相邻字幕里有 4 对这样
  test('相邻两行字幕不许共享同一帧', () {
    // 510 毫秒不落在帧点上（30fps 的第 15 帧是 500 毫秒）——裸四舍五入
    // 会把第 15 帧同时判给两行
    final track = const SubtitleTrack.empty().withLines(
      const SubtitleSlot(unitUid: 'u0', shotIndex: 0),
      const [
        SubtitleLine(startMs: 0, endMs: 510, text: '甲'),
        SubtitleLine(startMs: 510, endMs: 1000, text: '乙'),
      ],
    );
    final r = subtitleShotReport(task().copyWith(subtitleTrack: track),
        unitIndex: 0, shotIndex: 0)!;
    final lines = (r['lines'] as List).cast<Map<String, dynamic>>();
    final a = (lines[0]['frames'] as List).cast<int>();
    final b = (lines[1]['frames'] as List).cast<int>();
    expect(b.first, a.last + 1,
        reason: '同一帧不能既是上一行的末帧、又是下一行的首帧——'
            '整条轴选「帧」而不是「毫秒」就是为了这个');
  });

  /// 真机任务 #1 的 U1 是**手动加的单元**（`hasSource: false`、`shots: []`），
  /// 在成片里占 0~299 帧，而 `subtitle show` 里一行都没有：报告顶上写
  /// `totalFrames: 3227`，第一行却从第 300 帧开始，那 300 帧属于谁、
  /// 为什么没字幕，报告一个字不说。
  ///
  /// Task 6 修过同一个洞的镜头层版本——「Agent 看到的是这段镜头凭空消失，
  /// 连它存在过都不知道」。同一句话在单元这一层照样成立，何况**手动加的
  /// 单元正是设计文档 §2.5 论证「必须用成片轴」的唯一论据**：轴立了，
  /// 却唯独看不见它
  RenewTask taskWithShotlessUnit() => RenewTask(
        id: 't5', name: '测试5', status: RenewTaskStatus.ready,
        createdAt: DateTime(2026, 9, 20), updatedAt: DateTime(2026, 9, 20),
        videoInfo: VideoInfo(
            width: 1080, height: 1920, fps: 30,
            duration: const Duration(milliseconds: 3000),
            fpsExact: Rational.fps30,
            fileSizeBytes: 0),
        units: const [
          // 手动加的单元：原片里没有它，也没切出视觉镜头
          SemanticUnit(
            uid: 'u-manual', index: 0, startMs: 0, endMs: 1000,
            transcript: '手动加的', hasSource: false, shots: [],
          ),
          SemanticUnit(
            uid: 'u0', index: 1, startMs: 0, endMs: 2000, transcript: '甲乙',
            shots: [
              Shot(startMs: 0, endMs: 1000),
              Shot(startMs: 1000, endMs: 2000),
            ],
          ),
        ],
      );

  test('没有自己镜头的单元，照样占一行——不许在报告里凭空消失', () {
    final rows =
        (subtitleReport(taskWithShotlessUnit())['shots'] as List).cast<Map>();
    final row = rows.firstWhere((r) => r['at'] == 'U1',
        orElse: () => throw StateError('U1 整行不见了'));
    expect(row['at'], 'U1', reason: '没有镜头就不带 S');
    expect(row['unit'], 0);
    expect(row['unitUid'], 'u-manual');
    expect(row['frames'], [0, 29],
        reason: 'ComposedFrames.unitSpan 算得出它的确切帧区间，'
            '报出来不是编数字');
    expect(row['voice'], 'none');
    expect(row['note'], isNotNull,
        reason: '那几帧属于谁、为什么没字幕，报告得说一句');
    expect(row.containsKey('shot'), isFalse,
        reason: '它没有镜头下标，编一个出来 Agent 会拿去敲 --shot');
  });

  test('第一行的首帧要接上片头，不许从半截开始', () {
    final rows =
        (subtitleReport(taskWithShotlessUnit())['shots'] as List).cast<Map>();
    expect((rows.first['frames'] as List).first, 0,
        reason: 'totalFrames 从 0 算起，报告第一行却从第 30 帧开始的话，'
            '开头那 30 帧就是一段无人认领的空白');
  });

  test('单镜报告带上 caption：字幕落在画面哪个矩形，纯计算', () {
    final r = subtitleShotReport(task(), unitIndex: 0, shotIndex: 0)!;
    final caption = r['caption'] as Map;
    expect(caption['maxCharsPerScreen'], isA<int>());
    expect(caption['willWrap'], isA<bool>());
    final box = caption['box'] as Map;
    expect(box['left'], lessThan(box['right']));
  });

  test('已经切成几屏、每屏都放得下时，willWrap 不许跟 problems 打架', () {
    // 字幕轨手改成三行，每行都 <= maxCharsPerScreen（默认字号下是 15），
    // 加起来远超——拼起来求和的话 willWrap 会是 true，而这三行本来就
    // 每屏都放得下，problems 里也不该报 captionOverflows
    final track = const SubtitleTrack.empty().withLines(
      const SubtitleSlot(unitUid: 'u0', shotIndex: 0),
      const [
        SubtitleLine(startMs: 0, endMs: 300, text: '一二三四五六七八九十'),
        SubtitleLine(startMs: 300, endMs: 600, text: '甲乙丙丁戊己庚辛壬癸'),
        SubtitleLine(startMs: 600, endMs: 900, text: '子丑寅卯辰巳午未申酉'),
      ],
    );
    final r = subtitleShotReport(task().copyWith(subtitleTrack: track),
        unitIndex: 0, shotIndex: 0)!;
    final caption = r['caption'] as Map;
    expect(caption['willWrap'], isFalse,
        reason: '每屏都放得下。拼起来求和的话这里会是 true，'
            '而 problems 里不报 captionOverflows——同一份报告两个相反的事实');
    final kinds = ((r['problems'] as List?) ?? const [])
        .map((p) => (p as Map)['kind'])
        .toSet();
    expect(kinds, isNot(contains('captionOverflows')));
  });

  /// **自动切出来的行并没有「过了分屏那一关」。**
  ///
  /// 替换裂变的自动行走 `subtitleLinesForSlot → subtitleLinesInSlot`，
  /// 那里按**写死的 18 字**切（`subtitle_overlay.dart` 的 `_maxCharsPerLine`），
  /// 跟 `SubtitleStyle.maxCharsPerScreen` 毫无关系。所以字号一调大，
  /// 自动行必然大量超——真机任务 #1 是 43 条超长、手改 0 镜，正好反证
  /// 「真会超的是手改过的行」那句注释
  test('字号调大之后，没人碰过的自动行照样会超', () {
    final t = RenewTask(
      id: 't6', name: '测试6', status: RenewTaskStatus.ready,
      createdAt: DateTime(2026, 9, 20), updatedAt: DateTime(2026, 9, 20),
      videoInfo: VideoInfo(
          width: 1080, height: 1920, fps: 30,
          duration: const Duration(milliseconds: 2000),
          fpsExact: Rational.fps30,
          fileSizeBytes: 0),
      // 0.065 下一屏只放得下 7 个字（真机 U2S3 就是这个字号）
      subtitle: const SubtitleStyle(fontRatio: 0.065),
      asrSentences: const [
        AsrSentence(startMs: 0, endMs: 1000, text: '一二三四五六七八九十', words: [
          AsrWord(startMs: 0, endMs: 100, text: '一'),
          AsrWord(startMs: 100, endMs: 200, text: '二'),
          AsrWord(startMs: 200, endMs: 300, text: '三'),
          AsrWord(startMs: 300, endMs: 400, text: '四'),
          AsrWord(startMs: 400, endMs: 500, text: '五'),
          AsrWord(startMs: 500, endMs: 600, text: '六'),
          AsrWord(startMs: 600, endMs: 700, text: '七'),
          AsrWord(startMs: 700, endMs: 800, text: '八'),
          AsrWord(startMs: 800, endMs: 900, text: '九'),
          AsrWord(startMs: 900, endMs: 1000, text: '十'),
        ]),
      ],
      units: const [
        SemanticUnit(
          uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '一二三',
          shots: [
            Shot(startMs: 0, endMs: 1000),
            Shot(startMs: 1000, endMs: 2000),
          ],
        ),
      ],
    );
    final r = subtitleShotReport(t, unitIndex: 0, shotIndex: 0)!;
    expect((r['lines'] as List).first, isA<Map>());
    expect(((r['lines'] as List).first as Map)['by'], 'auto',
        reason: '没人碰过这一镜');
    final kinds = ((r['problems'] as List?) ?? const [])
        .map((p) => (p as Map)['kind'])
        .toSet();
    expect(kinds, contains('captionOverflows'),
        reason: '自动分行按写死的 18 字切，跟 maxCharsPerScreen 无关——'
            '「自动行本来就过了分屏那一关」是句假话');
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

  test('查过了、画面干净：burned 是空数组，不是整个键不见', () {
    final dataDir =
        Directory.systemTemp.createTempSync('subtitle_view_test_');
    addTearDown(() => dataDir.deleteSync(recursive: true));
    frameCheckCacheIn(dataDir).put(7, const FrameCheck(burnedText: []));

    final r = subtitleShotReport(taskWithShotCandidate(),
        unitIndex: 0, shotIndex: 0, dataDir: dataDir)!;
    expect(r.containsKey('burned'), isTrue,
        reason: '「查了，干净」和「根本没查」必须分得开——'
            '后者才是整个键不出现');
    expect(r['burned'], isEmpty);
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
