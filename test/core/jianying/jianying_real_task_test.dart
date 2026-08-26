@Tags(['real-data'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/jianying/jianying_writer.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:path/path.dart' as p;

/// 拿真机上的**真实任务**跑一遍——只报「单测通过」不算数。
///
/// 需要本机存在 ishkafel 的数据目录与 2 号任务；不满足时整组跳过，
/// 不让 CI 因为别人机器上没有这份数据而红。
void main() {
  final home = Platform.environment['HOME'] ?? '';
  final dataDir = p.join(home, 'Library', 'Application Support',
      'com.jichuang.ishkafel', 'ishkafel_data');
  final taskFile = File(p.join(dataDir, 'tasks', 'hlhivnohoo.json'));

  test('2 号任务（28 行 / 143.76 秒）能完整生成草稿', () async {
    if (!taskFile.existsSync()) {
      markTestSkipped('本机没有 2 号任务的数据，跳过');
      return;
    }
    final task = jsonDecode(taskFile.readAsStringSync()) as Map<String, dynamic>;
    final doc = ScriptDoc.fromJson(task['script']);
    expect(doc.lines, hasLength(28));

    // 素材：miaoa 素材在 material_cache/<id>.*，本地源直接用它自己的路径
    String? sourceOf(LineShot shot) {
      final local = shot.localSource;
      if (local != null) return File(local).existsSync() ? local : null;
      final dir = Directory(p.join(dataDir, 'material_cache'));
      if (!dir.existsSync()) return null;
      for (final f in dir.listSync()) {
        if (p.basenameWithoutExtension(f.path) == '${shot.materialId}') {
          return f.path;
        }
      }
      return null;
    }

    // 配音：voices/<task>/<lineId>_<时间戳>.mp3，同一行取最新一次
    String? voiceOf(ScriptLine line) {
      final vo = line.voiceover;
      if (vo == null) return null;
      return File(vo.audioPath).existsSync() ? vo.audioPath : null;
    }

    String? bgmOf(int materialId) {
      final dir = Directory(p.join(dataDir, 'bgm_cache'));
      if (!dir.existsSync()) return null;
      for (final f in dir.listSync()) {
        if (p.basenameWithoutExtension(f.path) == '$materialId') {
          return f.path;
        }
      }
      return null;
    }

    final out = Directory.systemTemp.createTempSync('jy_real_');
    addTearDown(() => out.deleteSync(recursive: true));

    final writer = JianyingWriter(
      root: out.path,
      sourceOf: sourceOf,
      voiceOf: voiceOf,
      bgmOf: bgmOf,
    );

    final progress = <String>[];
    final r = await writer.write(doc,
        taskName: '2号任务真机',
        onProgress: (d, t, what) => progress.add('$what $d/$t'));

    // —— 与 Python 验证脚本在同一份数据上的结果对齐（143760ms / 55 段 / 65 屏）
    expect(r.totalMs, 143760, reason: '总时长必须与成片一致');
    final info =
        jsonDecode(File(p.join(r.folder, 'draft_info.json')).readAsStringSync())
            as Map<String, dynamic>;
    final tracks = info['tracks'] as List;
    Map<String, dynamic> trackOf(String type, {int skip = 0}) =>
        tracks.where((t) => t['type'] == type).skip(skip).first
            as Map<String, dynamic>;

    expect((trackOf('video')['segments'] as List), hasLength(55));
    // 62 屏 = `subtitleScreensAt` 在这份数据上的结果，与界面预览逐屏一致。
    // （早先的验证脚本走 subtitle_overlay 的老规则、固定 18 字上限，出 65 屏；
    //  这里的 15 字上限是由本方案的字号 fontRatio 0.034 推导出来的）
    expect((trackOf('text')['segments'] as List), hasLength(62));
    expect((trackOf('audio')['segments'] as List), hasLength(27));
    expect((trackOf('audio', skip: 1)['segments'] as List), hasLength(4));

    // 字幕：一律无标点（原片字幕就是无标点的堆字风格）
    final texts = (info['materials'] as Map)['texts'] as List;
    final bad = <String>[];
    for (final t in texts) {
      final text = jsonDecode(t['content'] as String)['text'] as String;
      if (RegExp(r'[，。？！；：、…,?!;:（）()《》【】]').hasMatch(text)) bad.add(text);
    }
    expect(bad, isEmpty, reason: '字幕带标点是不合格的');

    // 每屏不许超过字号推导出来的上限——超了就会出画
    final over = <String>[];
    for (final t in texts) {
      final text = jsonDecode(t['content'] as String)['text'] as String;
      if (text.length > doc.subtitle.maxCharsPerScreen) over.add(text);
    }
    expect(over, isEmpty,
        reason: '每屏上限 ${doc.subtitle.maxCharsPerScreen} 字（由字号推导），超了字要出画');

    // 小数点要保住：69.9 不能被剥成 699
    final joined = [
      for (final t in texts) jsonDecode(t['content'] as String)['text'] as String
    ].join(' ');
    expect(joined, contains('69.9'), reason: '价格里的小数点不是句读');

    expect(progress, isNotEmpty);
    expect(r.materialCount, greaterThan(50));
  });
}
