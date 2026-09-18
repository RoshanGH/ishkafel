import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/plan_submission.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/core/replacement/picked_thumbs.dart';
import 'package:path/path.dart' as p;

/// Agent 挑的素材也要带上首帧图。
///
/// 2026-09-18 真机（另一台机器），用户原话：「在进入审核页面的时候，经常会
/// 出现没有首帧图的那种情况，就是全是黑的，但是鼠标放上去还能播放，其他的
/// 操作都正常的。」——截图里整屏候选卡全是「画面还没抽出来」。
///
/// 根因：下载首帧图的只有界面那条路（`PickedMaterialStore`）。
/// Agent 经 CLI 提交方案走的是 [collectPickedMaterials]，它只从**已有记录**
/// 里捡 `thumbPath`（`thumbPath: hit?.thumbPath`），从头到尾不下载。于是
/// 纯 Agent 挑的素材 `thumbPath` 永远是 null。
///
/// 这跟同一个函数上面已经修过的两条是**同一个形状**：素材时长、画面自查，
/// 都是「界面挑素材时会做、Agent 这条路上不做」。首帧图是第三条。
///
/// 后果落在人身上：审核页正是「Agent 挑完、人来把关」的地方，而它的全部意义
/// 就是看图判断。看不到图，这一步等于废了——Agent 用得越多越常见。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pickedthumb'));
  tearDown(() => dir.deleteSync(recursive: true));

  CandidateMaterial mat(int id, {String? thumbUrl = 'https://t/%d.jpg'}) =>
      CandidateMaterial(
        id: id,
        name: '素材$id',
        sceneDescription: '画面',
        thumbnailUrl: thumbUrl?.replaceAll('%d', '$id'),
        previewUrl: 'https://c/$id.mov',
        fileKey: 'k$id',
        tags: const [],
      );

  /// 假的下载：返回一段能认出来的字节
  Future<List<int>> fakeFetch(String url) async => [
        ...'JPEG:'.codeUnits,
        ...url.codeUnits,
      ];

  group('Agent 提交方案时把首帧图一起下下来', () {
    test('之前没挑过的素材，首帧图也要落到盘上', () async {
      final thumbs = PickedThumbs(dir: dir, fetch: fakeFetch);

      final picked = await collectPickedMaterials(
        candidateIds: {11, 12},
        known: const [],
        fetch: (id) async => mat(id),
        probeDurationMs: (id) async => 4000,
        fetchThumb: (id) => thumbs.ensure(mat(id)),
      );

      for (final m in picked) {
        expect(m.thumbPath, isNotNull,
            reason: '素材 ${m.id} 没有首帧图——审核页上这张卡会是'
                '一整块「画面还没抽出来」，而人正要靠画面决定留不留');
        expect(File(m.thumbPath!).existsSync(), isTrue,
            reason: '路径记下来了、文件却不在，等于换了一种方式没有图');
      }
    });

    test('已经挑过、但那次没拿到图的，这次补上', () async {
      final thumbs = PickedThumbs(dir: dir, fetch: fakeFetch);

      final picked = await collectPickedMaterials(
        candidateIds: {11},
        known: const [
          // 真机上就有这样的残缺记录：名字和时长都在，唯独没有图
          PickedMaterial(
              id: 11,
              name: '早就挑过了',
              voiceover: '',
              sceneDescription: '',
              thumbPath: null,
              durationMs: 20000),
        ],
        fetch: (id) async => mat(id),
        probeDurationMs: (id) async => 4000,
        fetchThumb: (id) => thumbs.ensure(mat(id)),
      );

      expect(picked.single.thumbPath, isNotNull,
          reason: '「已经存过的不重量」说的是时长，不该把缺的图也一起跳过');
      expect(picked.single.name, '早就挑过了', reason: '别的字段不该被冲掉');
    });

    test('已经有图的不重下', () async {
      final asked = <String>[];
      final thumbs = PickedThumbs(dir: dir, fetch: (url) async {
        asked.add(url);
        return fakeFetch(url);
      });
      final existing = File(p.join(dir.path, '11.jpg'))
        ..writeAsBytesSync([1, 2, 3]);

      final picked = await collectPickedMaterials(
        candidateIds: {11},
        known: [
          PickedMaterial(
              id: 11,
              name: '有图',
              voiceover: '',
              sceneDescription: '',
              thumbPath: existing.path,
              durationMs: 20000),
        ],
        fetch: (id) async => mat(id),
        probeDurationMs: (id) async => 4000,
        fetchThumb: (id) => thumbs.ensure(mat(id)),
      );

      expect(asked, isEmpty, reason: '同一条素材可能被好几个位置选中，下一次就够');
      expect(picked.single.thumbPath, existing.path);
    });

    test('素材库没给缩略图地址：留空，不假装有', () async {
      final thumbs = PickedThumbs(dir: dir, fetch: fakeFetch);

      final picked = await collectPickedMaterials(
        candidateIds: {11},
        known: const [],
        fetch: (id) async => mat(id, thumbUrl: null),
        probeDurationMs: (id) async => 4000,
        fetchThumb: (id) => thumbs.ensure(mat(id, thumbUrl: null)),
      );

      expect(picked.single.thumbPath, isNull,
          reason: '没有地址就是没有图。界面会如实说「画面还没抽出来」，'
              '比记一个指向空文件的路径强');
    });

    test('下载失败不连累这条素材：别的字段照样留下', () async {
      final thumbs = PickedThumbs(
          dir: dir, fetch: (url) async => throw const SocketException('断网'));

      final picked = await collectPickedMaterials(
        candidateIds: {11},
        known: const [],
        fetch: (id) async => mat(id),
        probeDurationMs: (id) async => 4000,
        fetchThumb: (id) => thumbs.ensure(mat(id)),
      );

      expect(picked.single.thumbPath, isNull);
      expect(picked.single.durationMs, 4000,
          reason: '一张缩略图下不来，不该把取段要用的时长也丢掉');
    });
  });

  group('落盘规矩', () {
    test('空响应不写文件——写了会留下一个存在但解不出来的图', () async {
      final thumbs = PickedThumbs(dir: dir, fetch: (_) async => const []);
      expect(await thumbs.ensure(mat(11)), isNull);
      expect(File(p.join(dir.path, '11.jpg')).existsSync(), isFalse,
          reason: '文件在、却解不出来，界面会画成一整块纯色底且一个字都不说');
    });

    test('半截文件不算命中：按内容非空判，不是按文件名存在判', () async {
      File(p.join(dir.path, '11.jpg')).writeAsBytesSync(const []);
      final thumbs = PickedThumbs(dir: dir, fetch: fakeFetch);

      final got = await thumbs.ensure(mat(11));

      expect(got, isNotNull);
      expect(File(got!).lengthSync(), greaterThan(0),
          reason: '上一次没下完留了个空壳，这次要重下——'
              '「文件名存在就当命中」会把空壳一直端出来');
    });
  });
}
