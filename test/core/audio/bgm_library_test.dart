import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_library.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';

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
    BgmLibrary(
      run: (binary, args) async {
        capture?.addAll(args);
        return ProcessResult(1, exitCode, _json(records), stderr);
      },
    );

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

      expect(page.single.durationMs, 16561,
          reason: '当成秒的话 16561 会显示成 4 小时 36 分，'
              '「裁还是循环」的判断也全反了');
    });

    test('标签从 publicTags / aiTags / personalTags 合并，没有 tagNames 这个字段',
        () async {
      final page = await _lib([
        _record(publicTags: ['轻快'], aiTags: ['电子', '轻快']),
      ]).search();

      expect(page.single.tags, ['轻快', '电子'], reason: '合并去重');
    });

    test('认出含人声的条目——它压在原片解说上会打架', () async {
      final page = await _lib([
        _record(id: 1, asrText: '{"text":"这么好的一块玻璃就这么扔了"}'),
        _record(id: 2, asrText: null),
      ]).search();

      expect(page.firstWhere((m) => m.id == 1).hasSpeech, isTrue);
      expect(page.firstWhere((m) => m.id == 2).hasSpeech, isFalse);
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

  group('外部数据不可信', () {
    test('缺时长的条目仍然收下，标为时长未知', () async {
      final page = await _lib([_record(duration: null)]).search();

      expect(page.single.durationMs, 0,
          reason: '整条丢掉的话，用户在库里看不到这首歌却又搜得到，更困惑');
    });

    test('缺 id 的条目丢掉，不牵连其余', () async {
      final page = await _lib([
        {'name': '坏数据'},
        _record(id: 7),
      ]).search();

      expect(page.single.id, 7);
    });

    test('CLI 失败时抛的是人话，不是退出码', () async {
      expect(
        () => _lib([], exitCode: 1, stderr: 'boom').search(),
        throwsA(isA<MiaoaException>()),
      );
    });
  });
}
