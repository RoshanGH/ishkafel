import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/rendered_cache.dart';
import 'package:ishkafel/core/script/speed_clip_renderer.dart';

/// 变速切片进的是预览的**画面轨**，而画面轨是主时钟。
/// 切片比声明的短一帧，整条轨就一路偏快，口播轨被反复往前拽——
/// 真机听感是声音忽大忽小、卡住反复念同几个字（导出侧一直有补尾，所以只有预览错）。
void main() {
  late Directory dir;
  final calls = <List<String>>[];

  setUp(() async {
    calls.clear();
    dir = await Directory.systemTemp.createTemp('speed_clip');
  });
  tearDown(() => dir.delete(recursive: true));

  SpeedClipRenderer build() => SpeedClipRenderer(
        cache: RenderedCache(
          dir: dir,
          run: (_, args) async {
            calls.add(args);
            File(args.last).writeAsBytesSync([0]); // 假装渲出来了
            return ProcessResult(1, 0, '', '');
          },
        ),
      );

  test('末尾补一段克隆帧——切片实际长度必须 ≥ 它在轨上声明的长度', () async {
    await build().render(
        materialId: 105378,
        sourcePath: '/m/105378.mp4',
        trimStartMs: 0,
        allocMs: 3315,
        speed: 1.5);

    final vf = calls.single[calls.single.indexOf('-vf') + 1];
    expect(vf, contains('setpts=PTS/1.5'), reason: '该变速还是要变速');
    expect(vf, contains('tpad=stop_mode=clone'),
        reason: '视频时长只能是帧的整数倍、坑位是任意毫秒，只能往长了补');
  });

  test('取的源长度 = 坑位 × 倍速', () async {
    await build().render(
        materialId: 1,
        sourcePath: '/m/1.mp4',
        trimStartMs: 2000,
        allocMs: 4000,
        speed: 2.0);
    final args = calls.single;
    expect(args[args.indexOf('-ss') + 1], '2.000');
    expect(args[args.indexOf('-t') + 1], '8.000',
        reason: '2 倍速下要出 4 秒画面，得从源里取 8 秒');
  });

  test('补尾之前渲的切片不许被复用——指纹要换掉', () async {
    // 旧指纹（没有 v2 前缀）的产物躺在缓存目录里，不能命中
    final r = build();
    final path = await r.render(
        materialId: 7,
        sourcePath: '/m/7.mp4',
        trimStartMs: 0,
        allocMs: 1000,
        speed: 1.25);
    expect(path, contains('clip_7'));
    expect(calls, hasLength(1), reason: '第一次要真渲');

    calls.clear();
    await r.render(
        materialId: 7,
        sourcePath: '/m/7.mp4',
        trimStartMs: 0,
        allocMs: 1000,
        speed: 1.25);
    expect(calls, isEmpty, reason: '同一份内容第二次直接命中缓存，不重跑 ffmpeg');
  });
}
