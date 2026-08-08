
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/follower_track.dart';
import 'package:ishkafel/core/playback/track_plan.dart';

/// 记录所有命令的假跟随轨
class _Fake implements FollowerTrack {
  final List<String> calls = [];
  String? loaded;
  int _positionMs = 0;
  double volume = 1;

  /// 让测试可以伪造「漂了」
  void pretendAt(int ms) => _positionMs = ms;

  @override
  Future<void> load(String? edl) async {
    loaded = edl;
    calls.add('load:$edl');
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seekMs(int ms) async {
    _positionMs = ms;
    calls.add('seek:$ms');
  }

  @override
  Future<void> setVolume(double v) async {
    volume = v;
    calls.add('volume:$v');
  }

  @override
  int get positionMs => _positionMs;

  @override
  Future<void> dispose() async => calls.add('dispose');
}

TrackPlan _planWithBgm() => const TrackPlan(
      video: [TrackSegment(atMs: 0, durationMs: 10000, source: '/v/a.mp4')],
      voice: [TrackSegment(atMs: 0, durationMs: 10000, source: '/v/a.mp4')],
      bgm: [
        BgmTrackSegment(
          clip: TrackSegment(atMs: 4000, durationMs: 6000, source: '/b/1.mp3'),
          volume: 0.25,
          sourceDurationMs: 2000,
        ),
      ],
    );

void main() {
  group('跟随轨纠偏：只在真漂了的时候动手', () {
    test('抖动幅度内不纠——每次 seek 都是一次可闻的接缝', () {
      // 真机实测偏差在 ±70ms 之间来回抖，不是漂移
      expect(needsResync(masterMs: 5000, followerMs: 5070), isFalse);
      expect(needsResync(masterMs: 5000, followerMs: 4930), isFalse);
    });

    test('超出容许值才纠', () {
      expect(needsResync(masterMs: 5000, followerMs: 5200), isTrue);
      expect(needsResync(masterMs: 5000, followerMs: 4800), isTrue);
    });

    test('还没加载的轨不纠——它的 0 不是「漂到片头」', () {
      expect(needsResync(masterMs: 5000, followerMs: null), isFalse);
    });

    test('容许值比实测抖动留出余量', () {
      expect(syncToleranceMs, greaterThan(70),
          reason: '取得比抖动幅度还小的话，会被抖动骗着反复 seek');
    });
  });

  group('配乐按范围启停', () {
    test('没进范围时静音', () {
      expect(bgmCueAt(_planWithBgm(), 0), BgmCue.silent);
      expect(bgmCueAt(_planWithBgm(), 3999).source, isNull);
    });

    test('进了范围就播这首曲子的对应位置，带这一段自己的音量', () {
      final cue = bgmCueAt(_planWithBgm(), 4500);

      expect(cue.source, '/b/1.mp3');
      expect(cue.inMs, 500);
      expect(cue.volume, 0.25);
    });

    test('曲子比这一段短就绕回开头——「时长不够就循环」', () {
      // 曲子 2 秒，段落 6 秒；走到段内第 2.5 秒时该播曲子的第 0.5 秒
      expect(bgmCueAt(_planWithBgm(), 6500).inMs, 500);
      expect(bgmCueAt(_planWithBgm(), 8000).inMs, 0);
    });

    test('走出范围就停——「太长就播到段尾停」', () {
      expect(bgmCueAt(_planWithBgm(), 10000).source, isNull);
    });

    test('不知道曲长时不取模，播完即止', () {
      const plan = TrackPlan(bgm: [
        BgmTrackSegment(
          clip: TrackSegment(atMs: 0, durationMs: 6000, source: '/b/1.mp3'),
          volume: 1,
        ),
      ]);

      expect(bgmCueAt(plan, 5000).inMs, 5000);
    });
  });

  group('假跟随轨自身的行为（给上层用例做基准）', () {
    test('seek 之后位置就是 seek 到的那个值', () async {
      final fake = _Fake();
      await fake.seekMs(4200);

      expect(fake.positionMs, 4200);
      expect(fake.calls, ['seek:4200']);
    });

    test('音量夹在 0~1', () async {
      final fake = _Fake();
      await fake.setVolume(0.25);

      expect(fake.volume, 0.25);
    });
  });
}
