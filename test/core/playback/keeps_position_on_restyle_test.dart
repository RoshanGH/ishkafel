import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/follower_track.dart';
import 'package:ishkafel/core/playback/multitrack_playback.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/playback/track_plan.dart';

/// **换一段切片，人正看着的那一帧不能丢。**
///
/// 2026-09-09 真机：调字幕样式做成了「边调边看」，结果一动滑杆播放头就跳回
/// 片头——人正对着第 10.2 秒那一镜调字幕位置，一拖就被扔回 00:00，
/// 等于还是看不到自己在调什么。
///
/// 换源之后播放器的位置必然归零（重开了一个文件），所以 [MultitrackPlayback]
/// 换源前会记下**逻辑位置**（哪个单元、单元内偏移），换完再还原回去。
/// 这条线钉的就是这件事：只有切片路径变了（重烧了字幕）时，位置必须留在原处。
class _Fake implements FollowerTrack {
  String? loaded;
  int _positionMs = 0;
  @override
  Future<bool> load(String? edl) async {
    final changed = edl != loaded;
    loaded = edl;
    return changed;
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seekMs(int ms) async => _positionMs = ms;
  @override
  Future<void> setVolume(double v) async {}
  @override
  int get positionMs => _positionMs;
  @override
  Future<void> dispose() async {}
}

void main() {
  late FakePlaybackController master;
  late MultitrackPlayback playback;

  setUp(() {
    master = FakePlaybackController();
    playback = MultitrackPlayback(video: master, voice: _Fake(), bgm: _Fake());
  });
  tearDown(() => playback.dispose());

  /// 两个单元：U1 0~8000、U2 8000~16000。第二镜是重烧字幕的那一段
  TrackPlan planWith(String secondClip) => TrackPlan(
        video: [
          const TrackSegment(atMs: 0, durationMs: 6000, source: '/v/src.mp4'),
          TrackSegment(atMs: 6000, durationMs: 2000, source: secondClip),
          const TrackSegment(atMs: 8000, durationMs: 8000, source: '/v/src.mp4'),
        ],
        voice: const [
          TrackSegment(atMs: 0, durationMs: 16000, source: '/v/src.mp4'),
        ],
        unitRanges: const {0: (0, 8000), 1: (8000, 16000)},
      );

  test('只是重烧了字幕：人看的那一刻留在原处', () async {
    await playback.setPlan(planWith('/fit/old.mp4'));
    master.emitPosition(6800); // 人停在第二镜上调字幕
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await playback.setPlan(planWith('/fit/new.mp4'));

    expect(master.positionMs, 6800,
        reason: '跳回片头的话，人正对着调的那一帧就没了——'
            '「边调边看」当场变成看不到');
  });

  test('片长没变时是原样搬过去，不是按比例挪一点', () async {
    await playback.setPlan(planWith('/fit/old.mp4'));
    master.emitPosition(12345);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await playback.setPlan(planWith('/fit/new.mp4'));

    expect(master.positionMs, 12345);
  });
}
