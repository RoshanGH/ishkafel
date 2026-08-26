import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/jianying/jianying_writer.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jy_writer_');
    root = p.join(tmp.path, 'drafts');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String media(String name) {
    final f = File(p.join(tmp.path, name))..writeAsStringSync('x' * 512);
    return f.path;
  }

  ScriptDoc docWith(List<LineShot> shots) =>
      ScriptDoc([ScriptLine.create().withShots(shots)]);

  LineShot shot(String path, {int allocMs = 2000, double speed = 1.0}) =>
      LineShot(
        materialId: path.hashCode,
        name: p.basename(path),
        durationMs: 10000,
        allocMs: allocMs,
        speed: speed,
        localSource: path,
      );

  JianyingWriter writerFor() => JianyingWriter(
        root: root,
        sourceOf: (s) => s.localSource,
      );

  test('写出剪映认得的整套文件', () async {
    final r = await writerFor()
        .write(docWith([shot(media('a.mp4'))]), taskName: '2号任务');

    expect(Directory(r.folder).existsSync(), isTrue);
    final files = Directory(r.folder)
        .listSync()
        .map((e) => p.basename(e.path))
        .toSet();
    expect(
        files,
        containsAll([
          'draft_info.json',
          'draft_meta_info.json',
          'draft_agency_config.json',
          'draft_biz_config.json',
          'draft_settings',
          'draft_virtual_store.json',
          'key_value.json',
          'performance_opt_info.json',
          'timeline_layout.json',
          'materials',
        ]),
        reason: '缺文件剪映会把它当残缺草稿去补，补出来的默认值未必是我们要的');
  });

  test('两份 JSON 都是合法明文——剪映读明文，它自己保存时才加密', () async {
    final r = await writerFor()
        .write(docWith([shot(media('b.mp4'))]), taskName: 'T');
    final info = jsonDecode(File(p.join(r.folder, 'draft_info.json')).readAsStringSync())
        as Map<String, dynamic>;
    final meta = jsonDecode(
            File(p.join(r.folder, 'draft_meta_info.json')).readAsStringSync())
        as Map<String, dynamic>;
    expect(info['fps'], 30);
    expect(info['canvas_config'], {'width': 1080, 'height': 1920, 'ratio': 'original'});
    expect(info['duration'], 2000 * 1000, reason: '剪映的时间单位是微秒');
    expect(meta['draft_name'], r.name);
    expect(meta['draft_fold_path'], r.folder);
  });

  test('素材库里视频要出现——写空数组的话剪映素材面板里什么都没有', () async {
    final r = await writerFor().write(
        docWith([shot(media('c.mp4')), shot(media('d.mp4'))]),
        taskName: 'T');
    final meta = jsonDecode(
            File(p.join(r.folder, 'draft_meta_info.json')).readAsStringSync())
        as Map<String, dynamic>;
    final lib = (meta['draft_materials'] as List).first['value'] as List;
    expect(lib, hasLength(2));
    expect(lib.every((e) => e['metetype'] == 'video'), isTrue);
    expect(lib.first['file_Path'], startsWith(p.join(r.folder, 'materials')),
        reason: '素材库指的必须是落地后的路径，指回缓存目录剪映读不到');
  });

  test('素材落进草稿目录，删掉源文件草稿照样完整', () async {
    final source = media('e.mp4');
    final r = await writerFor().write(docWith([shot(source)]), taskName: 'T');
    File(source).deleteSync();
    final staged = Directory(p.join(r.folder, 'materials')).listSync();
    expect(staged, hasLength(1));
    expect(File(staged.single.path).readAsStringSync(), 'x' * 512);
    expect(r.materialCount, 1);
  });

  test('同一任务反复生成：序号递增，绝不覆盖', () async {
    final w = writerFor();
    final a = await w.write(docWith([shot(media('f.mp4'))]), taskName: '2号任务');
    final b = await w.write(docWith([shot(media('g.mp4'))]), taskName: '2号任务');
    expect(a.name, 'ishkafel_2号任务_1');
    expect(b.name, 'ishkafel_2号任务_2');
    expect(Directory(a.folder).existsSync(), isTrue,
        reason: '剪映打开过就会加密，覆盖等于毁掉用户已经做的精修');
  });

  test('进度要报出来——不许转圈不说话', () async {
    final seen = <String>[];
    await writerFor().write(docWith([shot(media('h.mp4'))]),
        taskName: 'T', onProgress: (d, t, what) => seen.add(what));
    expect(seen, isNotEmpty);
    expect(seen, contains('正在准备素材'));
  });

  test('变速原样落进 JSON', () async {
    final r = await writerFor().write(
        docWith([shot(media('i.mp4'), allocMs: 4000, speed: 0.26)]),
        taskName: 'T');
    final info = jsonDecode(File(p.join(r.folder, 'draft_info.json')).readAsStringSync())
        as Map<String, dynamic>;
    final seg = ((info['tracks'] as List).first['segments'] as List).first;
    expect(seg['speed'], 0.26);
    expect(seg['target_timerange']['duration'], 4000 * 1000);
    expect(seg['source_timerange']['duration'], (4000 * 0.26).round() * 1000);
  });
}
