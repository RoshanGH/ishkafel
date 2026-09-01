import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';
import 'package:ishkafel/core/miaoa/query_frame_uploader.dart';

/// 把本地那张图变成妙啊能用的查询帧。
///
/// 妙啊的以图搜视频只吃 OSS key，而复刻场景里最该拿去搜的那张图——
/// **参考片这一镜的首帧**——只在本地（打标时 ffmpeg 抽的）。这条最准的路
/// 因此一直是断的：手里攥着要复刻的那一帧，却只能先让 AI 把它写成一句话，
/// 再拿那句话去匹配别人写的另一句话。
///
/// 上传是要花时间、还会在素材库里留下东西的，所以**同一张图只传一次**，
/// 而且按**内容指纹**判重——按路径判会重复传，按「文件在不在」判会把
/// 上一张的结果放出来。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('qf'));
  tearDown(() => dir.deleteSync(recursive: true));

  File imageWith(String bytes, {String name = 'f.jpg'}) =>
      File('${dir.path}/$name')..writeAsStringSync(bytes);

  ({QueryFrameUploader up, List<List<String>> calls}) make({
    String ossId = 'prod/tenant-19/x/abc.jpg',
  }) {
    final calls = <List<String>>[];
    final gateway = MiaoaGateway(
      binary: 'miaoa',
      run: (bin, args, {environment, workingDirectory}) async {
        calls.add(args);
        return ProcessResult(
            0, 0, jsonEncode({'ok': true, 'ids': [1], 'ossId': ossId}), '');
      },
    );
    return (
      up: QueryFrameUploader(
          gateway: gateway, folderId: 2689, cacheDir: dir),
      calls: calls
    );
  }

  test('第一次：传上去，拿回 ossId', () async {
    final m = make();
    final key = await m.up.keyFor(imageWith('一帧'));
    expect(key, 'prod/tenant-19/x/abc.jpg');
    expect(m.calls.single, containsAll(['content', 'upload', '--type', 'image']),
        reason: '要按图片类型传，落到专门放查询帧的文件夹');
    expect(m.calls.single, contains('--json'),
        reason: '不加 --json 的话 ossId 会跑到 stderr 里，'
            '这里拿到的 stdout 只有一行给人看的「✓ 已创建 IMAGE #575」'
            '——上传成功却报失败，而且每点一次都重传一张');
    expect(m.calls.single, contains('2689'));
  });

  test('同一张图再要一次：不重复上传', () async {
    final m = make();
    final a = await m.up.keyFor(imageWith('一帧'));
    final b = await m.up.keyFor(imageWith('一帧'));
    expect(a, b);
    expect(m.calls.length, 1,
        reason: '上传要花时间、还往素材库里留东西，同一张图传两次是纯浪费');
  });

  test('内容一样但换了个文件名：还是同一张，不重传', () async {
    final m = make();
    await m.up.keyFor(imageWith('一帧', name: 'a.jpg'));
    await m.up.keyFor(imageWith('一帧', name: 'b.jpg'));
    expect(m.calls.length, 1,
        reason: '判重要按内容指纹——按路径判，同一帧换个名字就白传一次');
  });

  test('内容不一样：各传各的', () async {
    final m = make();
    await m.up.keyFor(imageWith('第一帧', name: 'a.jpg'));
    await m.up.keyFor(imageWith('另一帧', name: 'b.jpg'));
    expect(m.calls.length, 2);
  });

  test('传上去了却没拿到 ossId：直接失败，不许悄悄退回文字搜', () async {
    final gateway = MiaoaGateway(
      binary: 'miaoa',
      run: (bin, args, {environment, workingDirectory}) async =>
          ProcessResult(0, 0, jsonEncode({'ok': true}), ''),
    );
    final up =
        QueryFrameUploader(gateway: gateway, folderId: 2689, cacheDir: dir);
    await expectLater(up.keyFor(imageWith('一帧')), throwsStateError,
        reason: '人点的是「画面相似」。给他一批按文字搜出来的东西，'
            '他不会知道自己看的根本不是相似画面');
  });

  test('图都不在了：说清楚，别去传一个空文件', () async {
    final m = make();
    await expectLater(
        m.up.keyFor(File('${dir.path}/没有这张.jpg')), throwsStateError);
  });
}
