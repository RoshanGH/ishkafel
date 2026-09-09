import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/playback/edl.dart';
import 'package:ishkafel/core/playback/track_plan.dart';
import 'package:ishkafel/core/playback/track_plan_builder.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

const _src = '/v/原片.mp4';
const _vocals = '/v/纯人声.wav';

/// U1 = 0~4000（两个镜头）、U2 = 4000~10000（一个镜头）
List<SemanticUnit> _units() => const [
      SemanticUnit(
        uid: 'u0',
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: 'U1',
        shots: [
          Shot(startMs: 0, endMs: 2000),
          Shot(startMs: 2000, endMs: 4000),
        ],
      ),
      SemanticUnit(
        uid: 'u1',
        index: 1,
        startMs: 4000,
        endMs: 10000,
        transcript: 'U2',
        shots: [Shot(startMs: 4000, endMs: 10000)],
      ),
    ];

TrackPlan build({
  List<UnitReplacement> replacements = const [],
  Map<int, LocalMaterial> materials = const {},
  Map<String, String> speedFitted = const {},
  String? vocalsPath,
  Map<String, String> voiceAudio = const {},
  BgmPlan bgm = BgmPlan.empty,
  Map<int, String> bgmPaths = const {},
}) =>
    TrackPlanBuilder.build(
      sourcePath: _src,
      units: _units(),
      replacements: replacements,
      materials: materials,
      speedFitted: speedFitted,
      vocalsPath: vocalsPath,
      voiceAudio: voiceAudio,
      bgm: bgm,
      bgmPaths: bgmPaths,
    );

void main() {
  group('一处替换都没有：三条轨就是原片本身', () {
    test('画面与声音各一段，整条指向原片', () {
      final plan = build();

      expect(plan.video, [
        const TrackSegment(atMs: 0, durationMs: 10000, source: _src, inMs: 0),
      ], reason: '三个镜头首尾相接、同一个源，合成一段——写三段等于三次 seek');
      expect(plan.voice, hasLength(1));
      expect(plan.totalMs, 10000);
    });
  });

  group('整体替换：画面和声音都来自候选，时长跟候选走', () {
    test('候选比原来短，后面整体前移', () {
      final plan = build(
        replacements: [UnitReplacement.whole(const [71])],
        materials: {71: const LocalMaterial(path: '/m/71.mp4', durationMs: 2500)},
      );

      expect(plan.video.first.durationMs, 2500);
      expect(plan.video.first.source, '/m/71.mp4');
      expect(plan.video.first.inMs, 0, reason: '候选从头播');
      expect(plan.video[1].atMs, 2500, reason: 'U1 短了 1.5 秒，U2 跟着前移');
      expect(plan.video[1].inMs, 4000, reason: 'U2 播的还是原片那一段');
      expect(plan.totalMs, 8500);
    });

    test('声音也来自候选——整体替换是连声音一起换', () {
      final plan = build(
        replacements: [UnitReplacement.whole(const [71])],
        materials: {71: const LocalMaterial(path: '/m/71.mp4', durationMs: 2500)},
      );

      expect(plan.voice.first.source, '/m/71.mp4');
    });

    test('素材还没落到本地就当没选——宁可播原片，也不能播一个空洞', () {
      final plan = build(replacements: [UnitReplacement.whole(const [71])]);

      expect(plan.video.single.source, _src);
      expect(plan.totalMs, 10000);
    });

    test('探不出候选时长就按原坑位算，不拿 0 顶', () {
      final plan = build(
        replacements: [UnitReplacement.whole(const [71])],
        materials: {71: const LocalMaterial(path: '/m/71.mp4')},
      );

      expect(plan.video.first.durationMs, 4000);
      expect(plan.totalMs, 10000);
    });
  });

  group('镜头替换：只有标了 ★ 的那条需要预先变速', () {
    test('变速切片已经是坑位那么长，从头播', () {
      final plan = build(
        replacements: [
          UnitReplacement.perShot(const {
            1: [71]
          })
        ],
        speedFitted: {TrackPlanBuilder.shotKey(0, 1): '/fit/71.mp4'},
      );

      final fitted =
          plan.video.firstWhere((s) => s.source == '/fit/71.mp4');
      expect(fitted.atMs, 2000);
      expect(fitted.durationMs, 2000, reason: '坑位是 2 秒，切片也该是 2 秒');
      expect(fitted.inMs, 0);
    });

    test('没准备变速切片的镜头照播原片，不留空', () {
      final plan = build(
        replacements: [
          UnitReplacement.perShot(const {
            1: [71]
          })
        ],
      );

      expect(plan.video.single.source, _src);
    });

    test('镜头替换不改时长，也不改声音', () {
      final plan = build(
        replacements: [
          UnitReplacement.perShot(const {
            1: [71]
          })
        ],
        speedFitted: {TrackPlanBuilder.shotKey(0, 1): '/fit/71.mp4'},
      );

      expect(plan.totalMs, 10000);
      expect(plan.voice.single.source, _src,
          reason: '镜头替换只换画面，候选自己的声音要丢掉');
    });
  });

  group('声音按段落取源', () {
    test('换过音色的单元整段用配音', () {
      final plan = build(voiceAudio: {'u0': '/tts/u0.wav'});

      expect(plan.voice.first.source, '/tts/u0.wav');
      expect(plan.voice.first.durationMs, 4000);
    });

    test('被配乐盖住的段落改用纯人声——否则新配乐与原背景两首曲子一起响', () {
      final plan = build(
        vocalsPath: _vocals,
        bgm: BgmPlan.empty.assign(
            startUnit: 1,
            endUnit: 1,
            materials: [_track],
            rangeMs: 6000),
        bgmPaths: {9: '/local/9.mp3'},
      );

      expect(plan.voice.first.source, _src, reason: 'U1 没被盖住，用原混音');
      expect(plan.voice.last.source, _vocals);
    });

    test('没分离出纯人声时退回原混音，不留空', () {
      final plan = build(
        bgm: BgmPlan.empty.assign(
            startUnit: 1, endUnit: 1, materials: [_track], rangeMs: 6000),
        bgmPaths: {9: '/local/9.mp3'},
      );

      expect(plan.voice.every((s) => s.source == _src), isTrue);
    });
  });

  group('配乐轨', () {
    test('位置按成片时间轴算——整体替换会让它整体前移', () {
      final plan = build(
        replacements: [UnitReplacement.whole(const [71])],
        materials: {71: const LocalMaterial(path: '/m/71.mp4', durationMs: 2500)},
        bgm: BgmPlan.empty.assign(
            startUnit: 1, endUnit: 1, materials: [_track], rangeMs: 6000),
        bgmPaths: {9: '/local/9.mp3'},
      );

      expect(plan.bgm.single.clip.atMs, 2500,
          reason: '按原片算是 4000，那样配乐会晚 1.5 秒才响');
      expect(plan.bgm.single.clip.durationMs, 6000);
    });

    test('每段自己的音量', () {
      final plan = build(
        bgm: BgmPlan.empty.assign(
            startUnit: 0,
            endUnit: 1,
            materials: [_track],
            rangeMs: 10000,
            volume: 0.4),
        bgmPaths: {9: '/local/9.mp3'},
      );

      expect(plan.bgm.single.volume, 0.4);
    });

    test('曲子还没存到本地就不铺，但要说出来', () {
      final plan = build(
        bgm: BgmPlan.empty.assign(
            startUnit: 0, endUnit: 1, materials: [_track], rangeMs: 10000),
      );

      expect(plan.bgm, isEmpty);
      expect(plan.bgmMissing.single, contains('垫乐'));
    });

    test('按时刻找该播哪一段', () {
      final plan = build(
        bgm: BgmPlan.empty.assign(
            startUnit: 1, endUnit: 1, materials: [_track], rangeMs: 6000),
        bgmPaths: {9: '/local/9.mp3'},
      );

      expect(plan.bgmAt(1000), isNull);
      expect(plan.bgmAt(5000)?.clip.source, '/local/9.mp3');
    });
  });


  group('播放头换算回原片时刻', () {
    /// 用户原话：「播放到那个轨道，最后可能还剩 1/5，就直接跳到下一个台词
    /// 语义单元开始播放了。」——时间线上 U1 那个格子是按原片 4000ms 画的，
    /// 而成片里它只有 2000ms。1:1 映射会让播放头走到格子的一半就到头，
    /// 下一拍直接跳过去。
    test('整体替换段按比例走完整个格子，不提前跳走', () {
      final plan = build(
        replacements: [UnitReplacement.whole(const [71])],
        materials: {71: const LocalMaterial(path: '/m/71.mp4', durationMs: 2000)},
      );
      final whole = plan.video.first;

      expect(whole.durationMs, 2000, reason: '成片里只有 2 秒');
      expect(whole.sourceMsAt(0), 0);
      expect(whole.sourceMsAt(1000), 2000,
          reason: '走到成片一半时，播放头该在原片格子（0~4000）的一半');
      expect(whole.sourceMsAt(1999), 3998,
          reason: '走到成片末尾时该正好走到格子末尾，而不是停在 2000 再跳');
    });

    test('没被替换的段落还是一一对应，不做任何缩放', () {
      final plan = build();
      final segment = plan.video.single;

      expect(segment.sourceMsAt(0), 0);
      expect(segment.sourceMsAt(5000), 5000);
      expect(segment.sourceMsAt(9999), 9999);
    });

    test('整体替换之后的段落，播放头回到真实的原片时刻', () {
      final plan = build(
        replacements: [UnitReplacement.whole(const [71])],
        materials: {71: const LocalMaterial(path: '/m/71.mp4', durationMs: 2000)},
      );

      // U2 在成片里从 2000 开始，播的是原片 4000~10000
      final next = plan.video[1];
      expect(next.sourceMsAt(2000), 4000);
      expect(next.sourceMsAt(3000), 5000);
    });

    test('按比例的段不会被并进相邻段——并了映射就错了', () {
      final plan = build(
        replacements: [UnitReplacement.whole(const [71])],
        materials: {71: const LocalMaterial(path: '/m/71.mp4', durationMs: 2000)},
      );

      expect(plan.video, hasLength(2));
    });
  });

  group('拼成 EDL', () {
    test('每段写成「源,start=秒,length=秒」，分号隔开', () {
      final edl = Edl.of(const [
        TrackSegment(atMs: 0, durationMs: 2500, source: '/m/71.mp4'),
        TrackSegment(atMs: 2500, durationMs: 6000, source: _src, inMs: 4000),
      ]);

      expect(edl, startsWith('edl://'));
      expect(edl, contains('start=0.000,length=2.500'));
      expect(edl, contains('start=4.000,length=6.000'));
      expect(edl!.split(';'), hasLength(2));
    });

    test('路径按 mpv 的 %字节数% 规则转义——中文路径按 UTF-8 字节算', () {
      final edl = Edl.of(const [
        TrackSegment(atMs: 0, durationMs: 1000, source: '/视频/a,b.mp4'),
      ]);

      // '/视频/a,b.mp4' = 1+3+3+1+1+1+1+4 = 15 字节
      expect(edl, contains('%15%/视频/a,b.mp4'),
          reason: '不转义的话路径里的逗号会被当成参数分隔符');
    });

    test('空轨返回 null，不造一个空 EDL 塞给播放器', () {
      expect(Edl.of(const []), isNull);
    });
  });
}

const _track = BgmMaterial(
    id: 9, name: '垫乐', durationMs: 30000, previewUrl: 'https://cdn/b.mp3');
