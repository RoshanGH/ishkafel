import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/voice_sweep.dart';

/// 收掉这个任务里**不再被任何一行引用**的配音文件。
///
/// 换一次音色就多一批死 mp3：新配音换上去，旧文件还躺在
/// `voices/<taskId>/` 里。TaskArtifacts 的孤儿清扫只管「归属不到现存任务」
/// 的整个目录，任务还活着时它一个都不碰——所以这批文件谁都不管。
///
/// **不能在编辑当中删**：撤销栈里的旧版本还指着那些文件，删了就撤成死链
/// （真机上出现过整行无声）。所以只在**进入任务那一刻**扫一次——
/// 那时撤销栈必然是空的。
void main() {
  late Directory dir;
  late Directory voices;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voice_sweep_');
    voices = Directory('${dir.path}/voices/t1')..createSync(recursive: true);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File touch(String name) =>
      File('${voices.path}/$name')..writeAsStringSync('x');

  ScriptDoc docUsing(List<String> paths) => ScriptDoc([
        for (final path in paths)
          ScriptLine.create(text: '句').withVoiceover(LineVoiceover(
            audioPath: path,
            durationMs: 1000,
            sourceText: '句',
            voiceId: 'v',
            speechRate: 0,
          )),
      ]);

  test('用着的留下，没人引用的删掉', () {
    final live = touch('live.mp3');
    final dead = touch('dead.mp3');
    final removed = sweepUnusedVoices(
        dataDir: dir, taskId: 't1', doc: docUsing([live.path]));
    expect(removed, 1);
    expect(live.existsSync(), isTrue);
    expect(dead.existsSync(), isFalse);
  });

  test('一个都没用时全删——比如所有行的配音都被清掉了', () {
    touch('a.mp3');
    touch('b.mp3');
    expect(
        sweepUnusedVoices(dataDir: dir, taskId: 't1', doc: docUsing(const [])),
        2);
    expect(voices.listSync(), isEmpty);
  });

  test('目录不存在时不炸，返回 0', () {
    expect(
        sweepUnusedVoices(
            dataDir: dir, taskId: '没这个任务', doc: docUsing(const [])),
        0);
  });

  test('不碰别的任务的目录', () {
    final other = Directory('${dir.path}/voices/t2')..createSync();
    final f = File('${other.path}/x.mp3')..writeAsStringSync('x');
    sweepUnusedVoices(dataDir: dir, taskId: 't1', doc: docUsing(const []));
    expect(f.existsSync(), isTrue);
  });

  test('子目录不动——这里只收自己认识的那层文件', () {
    final sub = Directory('${voices.path}/sub')..createSync();
    sweepUnusedVoices(dataDir: dir, taskId: 't1', doc: docUsing(const []));
    expect(sub.existsSync(), isTrue);
  });
}
