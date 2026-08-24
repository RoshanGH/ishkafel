import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/director/export_readiness.dart';
import 'package:ishkafel/features/picking/picked_media_cache.dart';

void main() {
  const shot = (id: 1, name: '厨房特写', isBgm: false);
  const bgm = (id: 9, name: '快乐的尤克里里', isBgm: true);

  MediaReadiness check(Map<int, PickedMediaStatus?> status,
          {Map<int, String> reasons = const {}}) =>
      checkMedia([shot, bgm],
          statusOf: (n) => status[n.id],
          failureOf: (n) => reasons[n.id]);

  test('都在本地：可以开导', () {
    final r = check({
      1: PickedMediaStatus.ready,
      9: PickedMediaStatus.ready,
    });
    expect(r.canExport, isTrue);
    expect(r.ready, 2);
  });

  test('还在下：不算失败，等它——人已经点了导出，不该被赶回去', () {
    final r = check({
      1: PickedMediaStatus.ready,
      9: PickedMediaStatus.downloading,
    });
    expect(r.canExport, isFalse);
    expect(r.pending, 1);
    expect(r.failed, isEmpty, reason: '「在下」和「下砸了」是两回事');
  });

  test('刚排上队还没开始下，也是等，不是失败', () {
    final r = check({
      1: PickedMediaStatus.absent,
      9: PickedMediaStatus.ready,
    });
    expect(r.pending, 1);
    expect(r.failed, isEmpty);
  });

  test('下不下来：点名并带上能照做的原因', () {
    final r = check({
      1: PickedMediaStatus.ready,
      9: PickedMediaStatus.failed,
    }, reasons: {
      9: '妙啊登录已过期，请重新登录后重试',
    });
    expect(r.canExport, isFalse);
    expect(r.failed.single.name, '快乐的尤克里里');
    expect(r.failed.single.reason, '妙啊登录已过期，请重新登录后重试');
    expect(r.failed.single.isBgm, isTrue, reason: '配乐和画面素材的出路不一样');
  });

  test('原因取不到时也得有一句话，不许空着', () {
    final r = check({1: PickedMediaStatus.failed, 9: PickedMediaStatus.ready});
    expect(r.failed.single.reason, isNotEmpty);
  });

  test('没有下载器托管的项当作就绪——交给导出前最后一道闸判定', () {
    final r = check({1: null, 9: null});
    expect(r.canExport, isTrue);
  });
}
