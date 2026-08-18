import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_library.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';

/// miaoa `content search --type audio` 的真实返回形状（字段名取自真机探针）
String _json(List<Map<String, dynamic>> records) => jsonEncode({
      'records': records,
      'total': records.length,
    });

Map<String, dynamic> _record({
  int id = 1,
  String name = '轻快电子',
  num? duration = 30500,
  String? url = 'https://oss/a.mp3',
  List<String>? publicTags,
  List<String>? aiTags,
  String? asrText,
}) =>
    {
      'id': id,
      'name': name,
      'mediaFile': {'duration': duration, 'previewUrl': url},
      'publicTags': publicTags,
      'aiTags': aiTags,
      'personalTags': null,
      'asrText': asrText,
    };

BgmLibrary _lib(List<Map<String, dynamic>> records,
        {int exitCode = 0, String stderr = '', List<String>? capture}) =>
    BgmLibrary(gateway: MiaoaGateway(run: (binary, args) async {
        capture?.addAll(args);
        return ProcessResult(1, exitCode, _json(records), stderr);
      }, binary: 'miaoa'));

/// 带项目条件时返回 [scoped]、不带时返回 [all]——用来验「项目内为空就放开」
BgmLibrary _libByScope({
  required List<Map<String, dynamic>> scoped,
  required List<Map<String, dynamic>> all,
  List<List<String>>? calls,
}) =>
    BgmLibrary(gateway: MiaoaGateway(run: (binary, args) async {
        calls?.add(args);
        final byProject = args.contains('--projects');
        return ProcessResult(1, 0, _json(byProject ? scoped : all), '');
      }, binary: 'miaoa'));

void main() {
  group('检索音频库', () {
    test('走 --type audio，而不是分镜库', () async {
      final args = <String>[];
      await _lib([_record()], capture: args).search();

      expect(args, containsAllInOrder(['--type', 'audio']),
          reason: '打成 storyboard 就会返回一堆画面素材，用户拿去当 BGM 全是空的');
      expect(args, contains('--json'));
    });

    test('时长按毫秒读——真机核对过：duration 与 asrText 的时间戳同一量纲',
        () async {
      final page = await _lib([_record(duration: 16561)]).search();

      expect(page.items.single.durationMs, 16561,
          reason: '当成秒的话 16561 会显示成 4 小时 36 分，'
              '「裁还是循环」的判断也全反了');
    });

    test('标签从 publicTags / aiTags / personalTags 合并，没有 tagNames 这个字段',
        () async {
      final page = await _lib([
        _record(publicTags: ['轻快'], aiTags: ['电子', '轻快']),
      ]).search();

      expect(page.items.single.tags, ['轻快', '电子'], reason: '合并去重');
    });

    test('认出含人声的条目——它压在原片解说上会打架', () async {
      final page = await _lib([
        _record(id: 1, asrText: '{"text":"这么好的一块玻璃就这么扔了"}'),
        _record(id: 2, asrText: null),
      ]).search();

      expect(page.items.firstWhere((m) => m.id == 1).hasSpeech, isTrue);
      expect(page.items.firstWhere((m) => m.id == 2).hasSpeech, isFalse);
    });

    test('按关键词搜时带上关键词', () async {
      final args = <String>[];
      await _lib([_record()], capture: args).search(keyword: '轻快');

      expect(args, containsAllInOrder(['--keyword', '轻快']));
    });

    test('关键词只有空白时当作不筛，而不是搜一个空串', () async {
      final args = <String>[];
      await _lib([_record()], capture: args).search(keyword: '   ');

      expect(args, isNot(contains('--keyword')));
    });
  });

  group('项目条件不能把音频库整个滤空', () {
    test('项目内一首都没有时，自动放开到全库并说明', () async {
      final calls = <List<String>>[];
      final page = await _libByScope(
        scoped: const [],
        all: [_record(id: 9, name: '快乐的尤克里里')],
        calls: calls,
      ).search(projectIds: const [104]);

      expect(page.items.single.id, 9,
          reason: '音频库不按成片项目归属：滴露的项目下一条音频都没有，'
              '硬筛的结果就是用户打开选配乐看到一片空白');
      expect(page.widenedFromProject, isTrue, reason: '界面要说明为什么给的不是本项目的');
      expect(calls.first, contains('--projects'), reason: '仍然先按项目找一遍');
      expect(calls.last, isNot(contains('--projects')));
    });

    test('项目内有货就用项目内的，不去全库多跑一趟', () async {
      final calls = <List<String>>[];
      final page = await _libByScope(
        scoped: [_record(id: 3)],
        all: [_record(id: 9)],
        calls: calls,
      ).search(projectIds: const [104]);

      expect(page.items.single.id, 3);
      expect(page.widenedFromProject, isFalse);
      expect(calls, hasLength(1));
    });

    test('全库也搜不到时不谎称放开过——那只是没搜到', () async {
      final page = await _libByScope(
        scoped: const [],
        all: const [],
      ).search(keyword: '不存在的曲子', projectIds: const [104]);

      expect(page.items, isEmpty);
      expect(page.widenedFromProject, isFalse);
    });

    test('本来就不限项目时只搜一次', () async {
      final calls = <List<String>>[];
      await _libByScope(scoped: const [], all: const [], calls: calls).search();

      expect(calls, hasLength(1));
    });
  });

  group('外部数据不可信', () {
    test('缺时长的条目仍然收下，标为时长未知', () async {
      final page = await _lib([_record(duration: null)]).search();

      expect(page.items.single.durationMs, 0,
          reason: '整条丢掉的话，用户在库里看不到这首歌却又搜得到，更困惑');
    });

    test('缺 id 的条目丢掉，不牵连其余', () async {
      final page = await _lib([
        {'name': '坏数据'},
        _record(id: 7),
      ]).search();

      expect(page.items.single.id, 7);
    });

    test('CLI 失败时抛的是人话，不是退出码', () async {
      expect(
        () => _lib([], exitCode: 1, stderr: 'boom').search(),
        throwsA(isA<MiaoaException>()),
      );
    });
  });
}
