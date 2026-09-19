import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/doc_watch.dart';

/// 这个任务在盘上变了没有。
///
/// 两个真机问题都出在这儿：
///
/// 1. **假阳性丢写**：Agent 可视模式改台词，界面被唤醒打开时内存里是旧
///    数据，之后界面任何一次自动保存都把旧的盖回去——CLI 报 ok，盘上没变
/// 2. **界面不跟随数据**：Agent 改了什么，界面完全不刷新，人「在旁边看着，
///    看到的是一块黑板」
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('doc_watch_');
    Directory('${dir.path}/tasks').createSync(recursive: true);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File task(String id, String body) =>
      File('${dir.path}/tasks/$id.json')..writeAsStringSync(body);

  test('内容变了 → 指纹变', () {
    final f = task('a', '{"id":"a"}');
    final before = taskFingerprint(dir, 'a');
    f.writeAsStringSync('{"id":"a","name":"改过"}');
    expect(taskFingerprint(dir, 'a'), isNot(before));
  });

  test('没动就不变——每轮都当成变了会一直重刷界面', () {
    task('a', '{"id":"a"}');
    expect(taskFingerprint(dir, 'a'), taskFingerprint(dir, 'a'));
  });

  test('只看这一个任务，别的任务变了不算', () {
    task('a', '{"id":"a"}');
    final before = taskFingerprint(dir, 'a');
    task('b', '{"id":"b"}');
    expect(taskFingerprint(dir, 'a'), before);
  });

  test('文件不在时给稳定值，不炸', () {
    expect(taskFingerprint(dir, '没有'), taskFingerprint(dir, '没有'));
  });

  group('自己写完之后的基线推进', () {
  /// **界面自己写完一次盘，基线只在「这段窗口里没别人写过」时才推。**
  ///
  /// 编导台保存完会顺手换一张封面（抽帧，**可能是秒级**），而封面写的是同一个
  /// `tasks/<id>.json`。这段窗口里 Agent 完全可能写了一次盘：
  ///
  /// - 不推基线 → 本页自己的封面写入会把下一次真改动误判成「Agent 改过」
  /// - **无条件推** → 推过 Agent 那一笔：跟随从此判「没变」不再重读
  ///   （**它那一笔人永远看不到**），而人下一次保存 `canOverwrite` 为真、
  ///   **整份 script 静默盖过去**

    test('这段窗口里没别人写过：推到写完之后那一份', () {
      expect(
          advanceBaselineAfterOwnWrite(
              current: 'A', before: 'A', after: 'B'),
          'B',
          reason: '不推的话，下一次真改动会被自己刚写的封面挡下来');
    });

    test('这段窗口里有别人写过：一步都不推', () {
      expect(
          advanceBaselineAfterOwnWrite(
              current: 'A', before: 'X', after: 'B'),
          'A',
          reason: '推过去就等于把 Agent 那一笔一并盖章认领了——'
              '跟随不再重读，人下一次保存静默覆盖它');
    });

    test('还没有基线（第一次落盘）：照样按同一条判据走', () {
      expect(
          advanceBaselineAfterOwnWrite(
              current: null, before: 'none', after: 'B'),
          null,
          reason: 'current 是 null 说明还没读过，`canOverwrite` 本来就放行，'
              '这里不该自作主张给它按一个基线');
    });
  });
}
