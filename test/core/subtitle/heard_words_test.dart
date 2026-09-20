import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/subtitle/heard_words.dart';
import 'package:ishkafel/core/subtitle/voice_source.dart';
import 'package:ishkafel/core/time/rational.dart';
import 'package:ishkafel/core/timeline/composed_frames.dart';

/// 「这一镜的画面里，人耳朵听到的是哪几个字？」
///
/// 这**不是**为了让字幕去对齐 ASR——产品负责人说得很清楚，时间对不上无所谓。
/// 它是 Agent 判断「这一镜该显示哪几个字」的唯一事实依据。
///
/// 听到什么 = 事实，软件给；显示什么 = 判断，Agent 定。两件事永不混写。
void main() {
  List<SemanticUnit> units() => const [
        SemanticUnit(
          uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '甲乙',
          shots: [
            Shot(startMs: 0, endMs: 1000),
            Shot(startMs: 1000, endMs: 2000),
          ],
        ),
      ];

  /// 「甲」在 0~500ms，「乙」横跨 900~1100ms —— 它骑在两镜的边界上
  const sentences = [
    AsrSentence(startMs: 0, endMs: 1100, text: '甲乙', words: [
      AsrWord(startMs: 0, endMs: 500, text: '甲', confidence: 0.99),
      AsrWord(startMs: 900, endMs: 1100, text: '乙', confidence: 0.42),
    ]),
  ];

  ComposedFrames framesOf({Map<int, int> whole = const {}}) =>
      ComposedFrames.of(
        timeline: ComposedTimeline.of(units: units(), wholeDurations: whole),
        fps: Rational.fps30,
      );

  Heard heardAt(int shotIndex,
          {VoiceSource source = VoiceSource.original,
          Map<int, int> whole = const {}}) =>
      heardInShot(
        frames: framesOf(whole: whole),
        units: units(),
        unitIndex: 0,
        shotIndex: shotIndex,
        source: source,
        originalSentences: sentences,
      );

  test('听到的字按成片帧轴落位', () {
    final h = heardAt(0);
    expect(h.text, contains('甲'));
    expect(h.words!.first.firstFrame, 0);
  });

  test('骑在边界上的字要点名它溢到了哪一镜', () {
    final spill = heardAt(0).words!.firstWhere((w) => w.text == '乙');
    expect(spill.spillsInto, 'U1S2',
        reason: '「第二句的最后一个字其实是下一个镜头的第一个字」——'
            '这个字段就是那句话的机械表达');
  });

  test('置信度带出来——低置信度是听错字的高发处', () {
    final low = heardAt(0).words!.firstWhere((w) => w.text == '乙');
    expect(low.confidence, 0.42);
  });

  test('整段替换：不给词级，也不编时间', () {
    final h = heardAt(0, source: VoiceSource.replaced, whole: {0: 5000});
    expect(h.words, isNull,
        reason: '时长跟着素材走，逐词位置只能按比例摊——那是假精度');
    expect(h.note, contains('已经不成立'));
  });

  test('手动加的单元：没有台词来源，如实说，不留空', () {
    final h = heardAt(0, source: VoiceSource.none);
    expect(h.words, isNull);
    expect(h.text, isEmpty);
    expect(h.note, isNotNull,
        reason: '空值和「听到的是空」要分得开');
  });

  /// 单元从原片第 5000 毫秒开始——**只有 startMs 非零，坐标接反才露馅**。
  /// 现有那五条用的是 startMs=0 的夹具，`ms - 0 == ms`，两个公式数值相同，
  /// 把 original/base 两个 wordOffsetToUnit 写反也照样全绿
  List<SemanticUnit> offsetUnits() => const [
        SemanticUnit(
          uid: 'u0', index: 0, startMs: 5000, endMs: 7000, transcript: '甲',
          shots: [Shot(startMs: 5000, endMs: 6000)],
        ),
      ];

  test('original 档：词的时间戳量的是原片，要减掉单元起点', () {
    final units = offsetUnits();
    final frames = ComposedFrames.of(
      timeline: ComposedTimeline.of(units: units, wholeDurations: const {}),
      fps: Rational.fps30,
    );
    final h = heardInShot(
      frames: frames,
      units: units,
      unitIndex: 0,
      shotIndex: 0,
      source: VoiceSource.original,
      // 原片绝对毫秒：5000~5500，落在单元内偏移 0~500
      originalSentences: const [
        AsrSentence(startMs: 5000, endMs: 5500, text: '甲', words: [
          AsrWord(startMs: 5000, endMs: 5500, text: '甲'),
        ]),
      ],
    );
    expect(h.words, isNotNull);
    expect(h.words!.single.firstFrame, 0,
        reason: '这个单元在成片里从第 0 帧开始，词又落在单元最开头——'
            '忘了减 unit.startMs 的话会算成第 150 帧');
  });

  /// base 档的夹具：固定过底片（`baseCandidateId` 非 null），
  /// 词的时间戳用**素材内**毫秒（从 0 起）
  List<SemanticUnit> baseUnits({List<AsrSentence>? baseSentences}) => [
        SemanticUnit(
          uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '甲',
          baseCandidateId: 1,
          baseSentences: baseSentences,
          shots: const [
            Shot(startMs: 0, endMs: 1000),
            Shot(startMs: 1000, endMs: 2000),
          ],
        ),
      ];

  Heard heardBaseAt(int shotIndex, {List<AsrSentence>? baseSentences}) {
    final units = baseUnits(baseSentences: baseSentences);
    final frames = ComposedFrames.of(
      timeline: ComposedTimeline.of(units: units, wholeDurations: const {}),
      fps: Rational.fps30,
    );
    return heardInShot(
      frames: frames,
      units: units,
      unitIndex: 0,
      shotIndex: shotIndex,
      source: VoiceSource.base,
      originalSentences: const [],
    );
  }

  test('base 档：还没转写过，就说还没转写过', () {
    final h = heardBaseAt(0, baseSentences: null);
    expect(h.words, isNull);
    expect(h.note, contains('还没转写'));
  });

  test('base 档：转过但这条素材没人说话，不许说成「还没转写」', () {
    final h = heardBaseAt(0, baseSentences: const []);
    expect(h.words, isNull);
    expect(h.note, isNot(contains('还没转写')),
        reason: '转过、只是没人说话，跟「还没转写过」是两回事，'
            'Agent 拿到假话会去触发一次没必要的转写');
  });

  /// 相邻两词在毫秒上共享边界（前一个的 endMs == 后一个的 startMs）。
  /// 这正是设计文档 §2.6 选「帧」而不是「毫秒」的唯一理由要挡住的那件事：
  /// 裸调 `frameAt` 首尾各四舍五入一次，两个词就会同时认领同一帧——
  /// 真机任务 #1 的 487 对相邻词里有 375 对是这样，而 Agent 是拿这些帧号
  /// 去判断「这个字属于哪一镜」的
  test('相邻两词不许共享同一帧', () {
    final units = [
      const SemanticUnit(
        uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '甲乙',
        shots: [Shot(startMs: 0, endMs: 2000)],
      ),
    ];
    final frames = ComposedFrames.of(
      timeline: ComposedTimeline.of(units: units, wholeDurations: const {}),
      fps: Rational.fps30,
    );
    final h = heardInShot(
      frames: frames,
      units: units,
      unitIndex: 0,
      shotIndex: 0,
      source: VoiceSource.original,
      originalSentences: const [
        AsrSentence(startMs: 0, endMs: 1000, text: '甲乙', words: [
          AsrWord(startMs: 0, endMs: 500, text: '甲'),
          AsrWord(startMs: 500, endMs: 1000, text: '乙'),
        ]),
      ],
    );
    final first = h.words!.first;
    final second = h.words![1];
    expect(second.firstFrame, first.lastFrame + 1,
        reason: '毫秒上 500 同时属于两个词，帧上必须只属于后一个');
  });

  /// 真机任务 #1 的 U2S2：`frames [379,417]`，`heard` 里却多出一个「那」，
  /// 而「那」的帧区间是 `[418,424]`——**整词在本镜之外，根本没有「后半截」**，
  /// 同一个「那」在 U2S3 的 `heard.words` 里又出现一次。
  /// 手册教 Agent 把 `heard` 和 `lines` 并排看，它照手册会判成「漏了一个
  /// 『那』」去补，把对的那一镜改错
  test('整词落在本镜帧区间之外的，不算进本镜', () {
    final units = [
      const SemanticUnit(
        uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '甲',
        shots: [
          Shot(startMs: 0, endMs: 1000),
          Shot(startMs: 1000, endMs: 2000),
        ],
      ),
    ];
    final frames = ComposedFrames.of(
      timeline: ComposedTimeline.of(units: units, wholeDurations: const {}),
      fps: Rational.fps30,
    );
    // 第一镜是帧 [0,29]。这个词 984~1100ms 的帧区间是 [30,32]——
    // 毫秒上跟第一镜还有 16 毫秒的重叠，帧上一帧都不沾
    const sentence = AsrSentence(startMs: 984, endMs: 1100, text: '那', words: [
      AsrWord(startMs: 984, endMs: 1100, text: '那'),
    ]);
    Heard at(int shotIndex) => heardInShot(
          frames: frames,
          units: units,
          unitIndex: 0,
          shotIndex: shotIndex,
          source: VoiceSource.original,
          originalSentences: const [sentence],
        );

    expect(at(0).text, isNot(contains('那')),
        reason: '整词在 [30,32]、本镜是 [0,29]，一帧都不沾——'
            '算进来就会被报成 wordSplit，而它根本没有「后半截」');
    expect(at(1).words!.single.text, '那',
        reason: '它属于第二镜，只属于第二镜');
  });

  test('词跨过不止一镜时，指的是它真正落进的那一镜', () {
    // 三个短镜头：0~200、200~400、400~3000。词从 50ms 一路说到 900ms，
    // 尾巴越过第二镜（约到 400ms 那个边界）落进第三镜
    final units = [
      const SemanticUnit(
        uid: 'u0', index: 0, startMs: 0, endMs: 3000, transcript: '甲',
        shots: [
          Shot(startMs: 0, endMs: 200),
          Shot(startMs: 200, endMs: 400),
          Shot(startMs: 400, endMs: 3000),
        ],
      ),
    ];
    final frames = ComposedFrames.of(
      timeline: ComposedTimeline.of(units: units, wholeDurations: const {}),
      fps: Rational.fps30,
    );
    final h = heardInShot(
      frames: frames,
      units: units,
      unitIndex: 0,
      shotIndex: 0,
      source: VoiceSource.original,
      originalSentences: const [
        AsrSentence(startMs: 0, endMs: 900, text: '甲', words: [
          AsrWord(startMs: 50, endMs: 900, text: '甲'),
        ]),
      ],
    );
    expect(h.words!.single.spillsInto, 'U1S3',
        reason: '它跨过了第二镜（U1S2），真正落进的是第三镜——'
            '「紧邻下一镜」这个假设在短镜头面前站不住');
  });
}
