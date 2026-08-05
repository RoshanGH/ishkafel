import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/features/workbench/bgm_audition.dart';

class _FakePlayer implements AuditionPlayer {
  final List<String> opened;
  final Object? failWith;
  bool disposed = false;

  _FakePlayer(this.opened, {this.failWith});

  @override
  Future<void> open(String url) async {
    if (failWith != null) throw failWith!;
    opened.add(url);
  }

  @override
  Future<void> dispose() async => disposed = true;
}

const _a = BgmMaterial(
    id: 1, name: '尤克里里', durationMs: 122000, previewUrl: 'https://o/a.mp3');
const _b = BgmMaterial(
    id: 2, name: '风声', durationMs: 152000, previewUrl: 'https://o/b.mp3');
const _noUrl =
    BgmMaterial(id: 3, name: '没地址的', durationMs: 3000, previewUrl: null);

void main() {
  test('点一条就响，再点同一条停下', () async {
    final opened = <String>[];
    final audition = BgmAudition(createPlayer: () => _FakePlayer(opened));

    await audition.toggle(_a);
    expect(audition.playingId, 1);
    expect(opened, ['https://o/a.mp3']);

    await audition.toggle(_a);
    expect(audition.playingId, isNull, reason: '同一条再点一次是「停」，不是重放');
  });

  test('换一条时上一条必须停掉——两首歌一起响没法比', () async {
    final players = <_FakePlayer>[];
    final audition = BgmAudition(createPlayer: () {
      final p = _FakePlayer(<String>[]);
      players.add(p);
      return p;
    });

    await audition.toggle(_a);
    await audition.toggle(_b);

    expect(audition.playingId, 2);
    expect(players.first.disposed, isTrue);
    expect(players.last.disposed, isFalse);
  });

  test('没有预览地址时说清楚，不装作在放', () async {
    final audition = BgmAudition(createPlayer: () => _FakePlayer(<String>[]));

    await audition.toggle(_noUrl);

    expect(audition.playingId, isNull);
    expect(audition.error, contains('播放'));
  });

  test('播放失败时退回未播状态，并给人话', () async {
    final audition = BgmAudition(
        createPlayer: () =>
            _FakePlayer(<String>[], failWith: Exception('404')));

    await audition.toggle(_a);

    expect(audition.playingId, isNull, reason: '按钮不能一直停在「正在放」');
    expect(audition.error, isNotNull);
    expect(audition.error, isNot(contains('Exception')), reason: '不摊原始异常');
  });

  test('关掉时把播放器一起收走，不让它在后台继续响', () async {
    late _FakePlayer player;
    final audition = BgmAudition(createPlayer: () {
      player = _FakePlayer(<String>[]);
      return player;
    });

    await audition.toggle(_a);
    await audition.shutdown();

    expect(player.disposed, isTrue);
    expect(audition.playingId, isNull);
  });

  test('停下之后再 notify 不会炸——浮层关闭与播放回调会撞车', () async {
    final audition = BgmAudition(createPlayer: () => _FakePlayer(<String>[]));
    await audition.toggle(_a);
    await audition.shutdown();

    // 已经收走了还去 toggle，是关闭瞬间点到按钮的真实情形
    await expectLater(audition.toggle(_b), completes);
    expect(audition.playingId, isNull);
  });
}
