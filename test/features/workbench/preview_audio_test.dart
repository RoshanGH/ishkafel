import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/audio_track_builder.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/workbench/preview_audio.dart';
import 'package:ishkafel/features/workbench/preview_composer.dart';

const _track = BgmMaterial(
    id: 9, name: '垫乐', durationMs: 30000, previewUrl: 'https://cdn/b.mp3');
const _voice = VoiceRef(id: 'zh_female_vv_uranus_bigtts', name: 'vivi');

List<SemanticUnit> _units({int endMs = 4000}) => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: endMs,
        transcript: 'U1',
        shots: [Shot(startMs: 0, endMs: endMs)],
      ),
    ];

RenewTask _task({
  BgmPlan bgm = BgmPlan.empty,
  VoicePlan voices = VoicePlan.empty,
  String? vocalsPath,
}) =>
    RenewTask(
      id: 't1',
      name: '片',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.editing,
      createdAt: DateTime.utc(2026, 8, 5),
      updatedAt: DateTime.utc(2026, 8, 5),
      bgm: bgm,
      voices: voices,
      vocalsPath: vocalsPath,
    );

/// 假混音器：不起进程，产出一个真实存在的文件
({AudioTrackBuilderFactory factory, List<int> builds, Directory dir}) _mixer({
  bool fail = false,
}) {
  final dir = Directory.systemTemp.createTempSync('ishkafel_pa_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final builds = <int>[];
  return (
    factory: (taskId) => AudioTrackBuilder(
          workDir: dir,
          run: (bin, args) async {
            builds.add(1);
            if (fail) return ProcessResult(1, 1, '', '合不出来');
            File(args.last).writeAsStringSync('x');
            return ProcessResult(1, 0, '', '');
          },
        ),
    builds: builds,
    dir: dir,
  );
}

const _noDebounce = Duration.zero;

void main() {
  _composerReuse();
  group('没配乐也没换音色', () {
    test('什么都不做，用原片自带的声音', () async {
      final playback = FakePlaybackController();
      final mixer = _mixer();
      final c = PreviewAudioController(
          playback: playback, factory: mixer.factory, debounce: _noDebounce);

      c.update(task: _task(), units: _units(), voiceAudio: const {});
      await Future<void>.delayed(Duration.zero);

      expect(mixer.builds, isEmpty, reason: '原片那条音轨就是正确答案，零开销');
      expect(c.state, PreviewAudioState.original);
      expect(playback.externalAudio, isNull);
    });
  });

  group('有配乐或配音时合一条挂上去', () {
    Future<PreviewAudioController> run({
      required RenewTask task,
      required AudioTrackBuilderFactory factory,
      FakePlaybackController? playback,
      Map<int, String> voiceAudio = const {},
    }) async {
      final c = PreviewAudioController(
          playback: playback ?? FakePlaybackController(),
          factory: factory,
          debounce: _noDebounce);
      c.update(task: task, units: _units(), voiceAudio: voiceAudio);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return c;
    }

    test('加了配乐就合成并挂上外挂音轨', () async {
      final playback = FakePlaybackController();
      final mixer = _mixer();

      final c = await run(
        task: _task(
            bgm: const BgmPlan([
              BgmSegment(
                  startUnit: 0, endUnit: 0, materials: [_track], fit: BgmFit.cut),
            ]),
            vocalsPath: '/v/vocals.wav'),
        factory: mixer.factory,
        playback: playback,
      );

      expect(c.state, PreviewAudioState.ready);
      expect(playback.externalAudio, isNotNull,
          reason: '预览要听到的是成品声音，不是原片那条');
    });

    test('换过音色同样要合——配音是替换原声，不合就听不到', () async {
      final mixer = _mixer();

      final c = await run(
        task: _task(voices: VoicePlan.empty.assign([0], _voice)),
        factory: mixer.factory,
      );

      expect(c.state, PreviewAudioState.ready);
      expect(mixer.builds, isNotEmpty);
    });

    test('与声音无关的改动不触发重合', () async {
      final mixer = _mixer();
      final task = _task(
          bgm: const BgmPlan([
        BgmSegment(startUnit: 0, endUnit: 0, materials: [_track], fit: BgmFit.cut),
      ]));
      final c = PreviewAudioController(
          playback: FakePlaybackController(),
          factory: mixer.factory,
          debounce: _noDebounce);

      c.update(task: task, units: _units(), voiceAudio: const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final first = mixer.builds.length;
      // 同一份方案再来一次（例如换了选中、改了标签）
      c.update(task: task, units: _units(), voiceAudio: const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(mixer.builds, hasLength(first),
          reason: '改标签、切选中都与声音无关，不该跑几秒的重合');
    });

    test('边界拖动过就要重合——每段的时长变了', () async {
      final mixer = _mixer();
      final task = _task(
          bgm: const BgmPlan([
        BgmSegment(startUnit: 0, endUnit: 0, materials: [_track], fit: BgmFit.cut),
      ]));
      final c = PreviewAudioController(
          playback: FakePlaybackController(),
          factory: mixer.factory,
          debounce: _noDebounce);

      c.update(task: task, units: _units(), voiceAudio: const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final first = mixer.builds.length;
      c.update(task: task, units: _units(endMs: 5000), voiceAudio: const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(mixer.builds.length, greaterThan(first));
    });

    test('合成失败时如实说明，并退回原声', () async {
      final mixer = _mixer(fail: true);

      final c = await run(
        task: _task(voices: VoicePlan.empty.assign([0], _voice)),
        factory: mixer.factory,
      );

      expect(c.state, PreviewAudioState.failed);
      expect(previewAudioNotice(c.state, c.failure), contains('原片的声音'),
          reason: '听到的不是成品时必须说清楚，否则用户以为配乐没生效');
    });

    test('没有 ffmpeg 时说清楚，而不是静默什么都不发生', () async {
      final c = PreviewAudioController(
          playback: FakePlaybackController(),
          factory: null,
          debounce: _noDebounce);

      c.update(
          task: _task(voices: VoicePlan.empty.assign([0], _voice)),
          units: _units(),
          voiceAudio: const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(c.state, PreviewAudioState.failed);
      expect(c.failure, contains('ffmpeg'));
    });
  });

  group('缺纯人声轨的提醒', () {
    test('加了配乐却没分离出人声：要说清两首曲子会叠在一起', () {
      final notice = missingVocalsNotice(
        const BgmPlan([
          BgmSegment(
              startUnit: 0, endUnit: 0, materials: [_track], fit: BgmFit.cut),
        ]),
        VoicePlan.empty,
        null,
      );

      expect(notice, contains('叠在一起'));
    });

    test('没加配乐就不提醒——原背景本来就该在', () {
      expect(missingVocalsNotice(BgmPlan.empty, VoicePlan.empty, null), isNull);
    });
  });

  group('取不到配乐时要能就地重试', () {
    test('invalidate 之后同一份方案会重新合成一遍', () async {
      final mixer = _mixer();
      final c = PreviewAudioController(
          playback: FakePlaybackController(),
          factory: mixer.factory,
          debounce: _noDebounce);
      final task = _task(bgm: BgmPlan.empty.assign(
          startUnit: 0, endUnit: 0, materials: [_track], rangeMs: 4000));

      c.update(task: task, units: _units(), voiceAudio: const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final first = mixer.builds.length;
      expect(first, greaterThan(0));

      // 方案没变：不该重复合成
      c.update(task: task, units: _units(), voiceAudio: const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(mixer.builds, hasLength(first));

      // 点了「重试」
      c.invalidate();
      c.update(task: task, units: _units(), voiceAudio: const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(mixer.builds.length, greaterThan(first),
          reason: '不清指纹的话重试等于没点——方案没变就直接跳过了');
    });
  });
}

void _composerReuse() {
  group('合成器每个任务只建一次', () {
    /// 合成器内部有段落级缓存。每次合成都新建一个，等于把缓存扔掉——
    /// 真机上这会让四十多段被反复重渲染，「正在合成预览音轨」永远挂在那儿。
    test('改一次方案不会换一个新的合成器', () async {
      final dir = Directory.systemTemp.createTempSync('ishkafel_pcr_');
      addTearDown(() => dir.deleteSync(recursive: true));
      var made = 0;
      final mixer = _mixer();

      final c = PreviewAudioController(
        playback: FakePlaybackController(),
        factory: mixer.factory,
        debounce: _noDebounce,
        composerFactory: (taskId) {
          made++;
          return PreviewComposer(
            run: (binary, args) async {
              await File(args.last).writeAsString('mp4');
              return ProcessResult(1, 0, '', '');
            },
            workDir: dir,
            fetchMaterial: (id) async {
              final f = File('${dir.path}/m$id.mp4')..writeAsStringSync('mp4');
              return f.path;
            },
          );
        },
      );

      for (final ids in [
        [71],
        [72],
        [73]
      ]) {
        c.update(
          task: _task(),
          units: _units(),
          voiceAudio: const {},
          replacements: [UnitReplacement.whole(ids)],
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(made, 1, reason: '每改一次方案就换一个新合成器，段落缓存就永远是空的');
      c.dispose();
    });
  });

  group('合成进度写进那句提示里', () {
    test('有进度时报第几段，并说明只合改动过的部分', () {
      final text = previewAudioNotice(
          PreviewAudioState.building, null, progress: (7, 46));

      expect(text, contains('7/46'));
      expect(text, contains('下次进来直接就能播'));
    });

    test('没有进度时退回原来那句，不显示一个假的 0/0', () {
      expect(previewAudioNotice(PreviewAudioState.building, null),
          '正在合成预览音轨（配乐/配音），稍后就能听到');
    });
  });
}
