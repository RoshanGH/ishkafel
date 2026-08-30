import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/frame_check.dart';
import 'package:ishkafel/core/ai/frame_check_cache.dart';

/// 素材库里的素材会被反复用到——同一个任务的不同单元、不同任务、不同人。
/// **一条素材看一次就够，不是每个任务看一次**。
///
/// 而且这份缓存让 `candidates` 能零成本地告诉 Agent「这条以前看过、
/// 画面上烧着字」——它此前只能先提交、等 `apply` 报错再回去重挑
/// （验收 Agent 原话：「人挑一次，我挑两次」）。
void main() {
  late Directory dir;
  late FrameCheckCache cache;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('fcc');
    cache = FrameCheckCache(dir: dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('存了能读回来', () {
    cache.put(7, const FrameCheck(burnedText: ['已售罄'], productBrand: '滴露',
        framesSeen: 3));
    final got = cache.get(7)!;
    expect(got.burnedText, ['已售罄']);
    expect(got.productBrand, '滴露');
    expect(got.framesSeen, 3);
  });

  test('没查过的返回 null——不是空结果', () {
    expect(cache.get(999), isNull);
  });

  test('看得更全的结果覆盖看得少的；反过来不覆盖', () {
    cache.put(7, const FrameCheck(framesSeen: 3, productBrand: '滴露'));
    cache.put(7, const FrameCheck(framesSeen: 1));
    expect(cache.get(7)!.productBrand, '滴露',
        reason: '一帧的结论顶不掉三帧的——那是把看全的退回没看全');
  });

  test('同样帧数时后来的覆盖先前的——素材本身可能被换过', () {
    cache.put(7, const FrameCheck(framesSeen: 3, productBrand: '滴露'));
    cache.put(7, const FrameCheck(framesSeen: 3, productBrand: '若也'));
    expect(cache.get(7)!.productBrand, '若也');
  });

  test('坏掉的缓存文件当作没查过，不炸', () {
    File('${dir.path}/7.json').writeAsStringSync('{坏');
    expect(cache.get(7), isNull);
  });

  test('缓存要有配额——不能在盘上无限长', () {
    for (var i = 0; i < FrameCheckCache.maxEntries + 20; i++) {
      cache.put(i, const FrameCheck(framesSeen: 3));
    }
    cache.prune();
    expect(dir.listSync().whereType<File>().length,
        lessThanOrEqualTo(FrameCheckCache.maxEntries));
  });

  test('清理时留下最近用过的', () {
    cache.put(1, const FrameCheck(framesSeen: 3, productBrand: '老的'));
    for (var i = 2; i < FrameCheckCache.maxEntries + 5; i++) {
      cache.put(i, const FrameCheck(framesSeen: 3));
    }
    cache.get(1); // 碰一下：它又变成最近用过的了
    cache.prune();
    expect(cache.get(1)?.productBrand, '老的');
  });
}
