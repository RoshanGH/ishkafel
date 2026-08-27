import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/gui_lock_guidance.dart';

/// 界面占着锁时，该给 Agent 说什么。
///
/// 原来说的是「等它结束，或**在 app 里强制接管**」——验收 Agent 的原话：
/// 「错误信息本身在教我去点界面。这句话对一个纯 CLI 的 Agent 是死路：
/// 它给出的唯一出路在界面上。」而且这时候「人」往往是 Agent 自己叫出来的
/// （`ui new-task` 建完就把界面停在新任务的编导台上），于是它被自己刚建的
/// 任务锁在门外，手册还告诉它「别硬重试、去问人」——根本没有人。
void main() {
  test('界面占着时：给出**命令行能走通**的出路', () {
    final msg = guiLockGuidance(holder: '人（编导台）', taskId: 't1');
    expect(msg, contains('ishkafel open'),
        reason: '得给一条命令，而不是让它去点界面上的按钮');
    expect(msg, isNot(contains('强制接管')),
        reason: '这句话把纯 CLI 的 Agent 推向 Computer Use');
  });

  test('说清是「界面开着」而不是「有人在忙」——那个人可能就是它自己', () {
    final msg = guiLockGuidance(holder: '人（编导台）', taskId: 't1');
    expect(msg, anyOf(contains('界面'), contains('这个任务的页面')));
  });

  test('另一个 Agent 占着：那才是真冲突，只能等', () {
    final msg = guiLockGuidance(holder: 'agent:999', taskId: 't1');
    expect(msg, contains('agent:999'));
    expect(msg, isNot(contains('ishkafel open')),
        reason: '把界面挪走对另一个 Agent 没用');
  });

  test('不知道是谁占着也要给条路', () {
    expect(guiLockGuidance(holder: null, taskId: 't1'), isNotEmpty);
  });
}
