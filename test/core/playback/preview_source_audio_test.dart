import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/audio/source_audio.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/playback/track_plan.dart';
import 'package:ishkafel/core/playback/track_plan_builder.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 预览也要能听出「原片这一镜的声音」选了哪一档——
/// 预览的全部意义就是「听到的就是要交付的」。
const _src = '/v/原片.mp4';
const _vocals = '/v/纯人声.wav';
const _background = '/v/纯背景.wav';

/// U1 两镜：S1 换过素材，S2 没换
List<SemanticUnit> _units({MaterialAudioMode? s1Mode}) => [
      SemanticUnit(
        uid: 'u0',
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: 'U1',
        shots: [
          Shot(startMs: 0, endMs: 2000, sourceAudioMode: s1Mode),
          const Shot(startMs: 2000, endMs: 4000),
        ],
      ),
    ];

TrackPlan _build({
  MaterialAudioMode? s1Mode,
  SourceAudioSetting sourceAudio = SourceAudioSetting.auto,
  Map<String, String> silentClips = const {},
  bool replaced = true,
  String? backgroundPath = _background,
}) =>
    TrackPlanBuilder.build(
      sourcePath: _src,
      units: _units(s1Mode: s1Mode),
      replacements: [
        if (replaced)
          UnitReplacement.perShot({
            0: [77]
          })
        else
          UnitReplacement.keepOriginal(),
      ],
      materials: const {},
      vocalsPath: _vocals,
      backgroundPath: backgroundPath,
      sourceAudio: sourceAudio,
      silentClips: silentClips,
    );

List<String> _voiceSources(TrackPlan plan) =>
    [for (final s in plan.voice) s.source];

void main() {
  test('没设过：两镜都读原混音（和以前一样）', () {
    expect(_voiceSources(_build()), everyElement(_src));
  });

  test('S1 选人声：只有它读人声轨，S2 照旧原混音', () {
    final plan = _build(s1Mode: MaterialAudioMode.vocals);
    expect(plan.voice.first.source, _vocals);
    expect(plan.voice.last.source, _src);
  });

  test('S1 选背景声：读背景轨', () {
    expect(_build(s1Mode: MaterialAudioMode.background).voice.first.source,
        _background);
  });

  test('S1 选不播放：读那段静音，时长一分不少', () {
    final plan = _build(
      s1Mode: MaterialAudioMode.none,
      silentClips: {TrackPlanBuilder.shotKey(0, 0): '/v/静音.wav'},
    );
    expect(plan.voice.first.source, '/v/静音.wav');
    expect(plan.voice.first.durationMs, 2000,
        reason: '少一段的话 EDL 会把洞压掉，后面全体提前');
    expect(plan.voice.first.inMs, 0, reason: '静音文件从头读，不是从原片那个位置');
  });

  test('静音还没渲好：先放原声，时间一点都不能少', () {
    // 退回原声之后两镜读的是同一个文件、首尾相接，会被合并成一段——
    // 合并本身没问题，要紧的是这一格的 4 秒一分不少
    final plan = _build(s1Mode: MaterialAudioMode.none);
    expect(_voiceSources(plan), everyElement(_src));
    expect(
        plan.voice.fold<int>(0, (sum, s) => sum + s.durationMs), 4000);
  });

  test('没换素材的镜头不受档位影响', () {
    final plan = _build(s1Mode: MaterialAudioMode.vocals, replaced: false);
    expect(_voiceSources(plan), everyElement(_src));
  });

  test('分离轨不在：先放原混音，但要说出来', () {
    final plan =
        _build(s1Mode: MaterialAudioMode.background, backgroundPath: null);
    expect(plan.voice.first.source, _src);
    expect(plan.sourceStemMissing, ['U1·S1'],
        reason: '预览可以退回原混音，但不说的话人听到的和导出的不是一回事');
  });

  test('全片打底也管用', () {
    final plan = _build(
        sourceAudio:
            const SourceAudioSetting(mode: MaterialAudioMode.vocals));
    expect(plan.voice.first.source, _vocals);
  });
}
