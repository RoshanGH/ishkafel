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
  // **读固定下来的 fixture，不读本机的活数据**。
  //
  // 这条测试原来直接读 `~/Library/.../tasks/<id>.json`——用户在界面上动一下
  // 那条片子，它就红一次（真机上就是这么挂的：字幕从 62 屏变成 60 屏）。
  // 而且它在别人机器上会 skip，等于只在一台机器上有效。
  //
  // 现在数据固定进仓库，素材用临时目录里的假文件顶上：断言锁的是**这份
  // 数据**算出来的结果，谁改自己的任务都不影响，同事机器上也真的会跑。
  final fixture =
      File(p.join('test', 'core', 'jianying', 'fixtures', 'task_28lines.json'));

  test('28 行 / 143.76 秒的真实方案能完整生成草稿', () async {
    final task = jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>;
    final doc = ScriptDoc.fromJson(task['script']);
    expect(doc.lines, hasLength(28));

    // 素材、配音、配乐都用临时目录里的占位文件：草稿生成只搬运路径、
    // 不解码内容，所以内容是什么不影响这条测试要验的东西
    final assets = Directory.systemTemp.createTempSync('jy_assets_');
    addTearDown(() => assets.deleteSync(recursive: true));
    String fake(String name) {
      final f = File(p.join(assets.path, name))
        ..writeAsBytesSync(List.filled(64, 0));
      return f.path;
    }

    String? sourceOf(LineShot shot) => fake('m${shot.materialId}.mp4');
    String? voiceOf(ScriptLine line) =>
        line.voiceover == null ? null : fake('${line.id}.mp3');
    String? bgmOf(int materialId) => fake('bgm$materialId.mp3');

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
    // 60 屏 = `subtitleScreensAt` 在**这份 fixture** 上的结果，与界面预览
    // 逐屏一致。字数上限 15 由本方案的字号 fontRatio 0.034 推导而来
    // （早先的验证脚本走 subtitle_overlay 的老规则、固定 18 字上限，出 65 屏）。
    //
    // 这个数字跟着 fixture 走：断句规则改了它就该变，那时连同 fixture
    // 一起更新——但**不该因为谁在界面上动了自己的片子而变**
    expect((trackOf('text')['segments'] as List), hasLength(60));
    expect((trackOf('audio')['segments'] as List), hasLength(27));
    expect((trackOf('audio', skip: 1)['segments'] as List), hasLength(5));

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
