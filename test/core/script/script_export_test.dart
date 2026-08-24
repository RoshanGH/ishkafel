import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/script_export.dart';

/// 导出的交付拦截：没就绪的行必须点名拦下（成片少一段是不允许的错）。
/// ffmpeg 用假 runner——这里验编排与拦截，不验像素。
LineVoiceover vo(int ms, {String text = '词'}) => LineVoiceover(
    audioPath: '/vo.mp3',
    durationMs: ms,
    sourceText: text,
    voiceId: 'v',
    speechRate: 0);

LineShot shot(int id, {int? alloc}) => LineShot(
    materialId: id, name: 's$id', durationMs: 8000, allocMs: alloc);

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('script_export'));
  tearDown(() => dir.delete(recursive: true));

  final commands = <List<String>>[];

  ScriptExportRunner runner({String? Function(int)? local}) =>
      ScriptExportRunner(
        workDir: dir,
        localPathOf: local ?? (_) => '/m.mp4',
        run: (_, args) async {
          commands.add(args);
          // 假 ffmpeg：把「输出文件」造出来，编排走得下去
          final out = args.last;
          if (!out.startsWith('-')) File(out).writeAsBytesSync([0]);
          return ProcessResult(1, 0, '', '');
        },
      );

  ScriptDoc readyDoc() {
    var doc = ScriptDoc.empty().updateText(0, '词');
    doc = doc.setVoiceoverById(doc.lines[0].id, vo(4000));
    doc = doc.setShotsById(doc.lines[0].id, [shot(1, alloc: 4000)]);
    return doc;
  }

  test('全部就绪：跑完并返回输出路径，进度一步步报', () async {
    final steps = <String>[];
    final out = await runner().export(
      doc: readyDoc(),
      outPath: '${dir.path}/out/成片.mp4',
      burnSubtitles: false,
      onProgress: (progress) => steps.add(progress.step),
    );
    expect(File(out).existsSync(), isTrue);
    expect(steps, isNotEmpty);
    expect(steps.last, '合成成片');
  });

  test('没配音 / 配音过期 / 没镜头 / 没分配 → 全部点名拦下', () async {
    var doc = ScriptDoc.empty().updateText(0, '没配音');
    doc = doc.insertAfter(0, text: '配音过期');
    doc = doc.insertAfter(1, text: '没镜头');
    doc = doc.insertAfter(2, text: '没分配');
    doc = doc.setVoiceoverById(doc.lines[1].id, vo(2000, text: '旧词'));
    doc = doc.setVoiceoverById(doc.lines[2].id, vo(2000, text: '没镜头'));
    doc = doc.setVoiceoverById(doc.lines[3].id, vo(2000, text: '没分配'));
    doc = doc.setShotsById(doc.lines[3].id, [shot(1)]);

    await expectLater(
      () => runner().export(doc: doc, outPath: '${dir.path}/out.mp4'),
      throwsA(isA<ScriptExportException>().having(
          (e) => e.message,
          'message',
          allOf(
              contains('第 1 行还没生成配音'),
              contains('第 2 行的台词改过了'),
              contains('第 3 行还没挑镜头'),
              contains('第 4 行的镜头还没分时长')))),
    );
  });

  test('素材不在本地 → 点名到行和镜头，绝不拿空画面顶上', () async {
    await expectLater(
      () => runner(local: (_) => null).export(
          doc: readyDoc(), outPath: '${dir.path}/out.mp4', burnSubtitles: false),
      throwsA(isA<ScriptExportException>().having((e) => e.message, 'message',
          contains('第 1 行第 1 镜的素材在本地找不到'))),
    );
  });

  test('原声默认不进成片——升级不许悄悄改变已有片子的声音', () async {
    commands.clear();
    await runner().export(
      doc: readyDoc(),
      outPath: '${dir.path}/out/成片.mp4',
      burnSubtitles: false,
    );
    final mixes = commands.where((c) => c.join(' ').contains('amix'));
    expect(mixes, isEmpty, reason: '没开原声就只有口播，不该多混一路');
  });

  test('开了原声：口播与素材原声一起混进成片，各自音量不被压小', () async {
    commands.clear();
    await runner().export(
      doc: readyDoc().withSourceVolume(0.3),
      outPath: '${dir.path}/out/成片.mp4',
      burnSubtitles: false,
    );
    final all = commands.map((c) => c.join(' ')).toList();
    expect(all.any((c) => c.contains('volume=0.300')), isTrue,
        reason: '原声按设定的音量缩放');
    expect(all.any((c) => c.contains('amix=inputs=2')), isTrue,
        reason: '口播与原声要混在一起');
    expect(all.any((c) => c.contains('normalize=0')), isTrue,
        reason: '默认的归一化会把口播也压小，听感上像口播突然变轻');
  });

  test('某一镜单独压掉原声：那一镜垫静音，别的镜头照旧', () async {
    commands.clear();
    var doc = readyDoc().withSourceVolume(0.5);
    doc = doc.setShotsById(doc.lines[0].id, [
      shot(1, alloc: 2000),
      shot(2, alloc: 2000),
    ]);
    doc = doc.setShotSourceVolumeById(doc.lines[0].id, 0, 0);
    await runner().export(
      doc: doc,
      outPath: '${dir.path}/out/成片.mp4',
      burnSubtitles: false,
    );
    final all = commands.map((c) => c.join(' ')).toList();
    expect(all.any((c) => c.contains('anullsrc')), isTrue,
        reason: '压掉的那一镜垫静音，时间轴不能塌');
    expect(all.any((c) => c.contains('volume=0.500')), isTrue,
        reason: '没单独设的镜头跟随整片');
  });

  test('空脚本直接拒绝', () async {
    await expectLater(
      () => runner().export(doc: ScriptDoc.empty(), outPath: '${dir.path}/o.mp4'),
      throwsA(isA<ScriptExportException>()),
    );
  });
}
