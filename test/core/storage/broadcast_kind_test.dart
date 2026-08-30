import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/agent_broadcast.dart';

/// 播报里混着两种完全不同的东西，人一眼分不开：
///
/// - **进度**：「正在给 U2S4 挑素材」——它走到哪儿了
/// - **判断**：「标签命中 5318 条太宽，改用画面描述再搜一轮」——它为什么
///   改主意了
/// - **发现问题**：「这条素材画面上烧着别家的字」——人可能要当场喊停
///
/// 三者挤在同一种样式里，人只会把它们当成一串流水账划过去。而人肯把花钱
/// 的活交给静默模式，靠的正是「我看懂过它是怎么想的」。
void main() {
  test('默认是进度——绝大多数播报都是它', () {
    final b = AgentBroadcast.empty.push('正在给 U2S4 挑素材');
    expect(b.lines.single.kind, BroadcastKind.step);
  });

  test('判断类要标出来', () {
    final b = AgentBroadcast.empty
        .push('标签命中 5318 条太宽，改用画面描述再搜一轮',
            kind: BroadcastKind.judgement);
    expect(b.lines.single.kind, BroadcastKind.judgement);
  });

  test('发现问题要标出来——人可能要当场喊停', () {
    final b = AgentBroadcast.empty
        .push('这条素材画面上烧着别家的字', kind: BroadcastKind.warning);
    expect(b.lines.single.kind, BroadcastKind.warning);
  });

  test('往前推的时候类型跟着那一条走，不会串到别的行上', () {
    final b = AgentBroadcast.empty
        .push('第一步')
        .push('改主意了', kind: BroadcastKind.judgement)
        .push('第三步');
    expect(b.lines.map((l) => l.kind).toList(),
        [BroadcastKind.step, BroadcastKind.judgement, BroadcastKind.step]);
  });

  test('标成做完不改变它是哪一类', () {
    final b = AgentBroadcast.empty
        .push('发现问题', kind: BroadcastKind.warning)
        .finish();
    expect(b.lines.single.kind, BroadcastKind.warning);
    expect(b.lines.single.done, isTrue);
  });

  test('留最近 5 条这条规矩不变', () {
    var b = AgentBroadcast.empty;
    for (var i = 0; i < 8; i++) {
      b = b.push('第 $i 步');
    }
    expect(b.lines.length, AgentBroadcast.maxLines);
    expect(b.lines.first.text, '第 3 步');
  });

  test('发现的问题不该被后面的流水账挤掉', () {
    var b = AgentBroadcast.empty
        .push('这条素材画面上烧着别家的字', kind: BroadcastKind.warning);
    for (var i = 0; i < 8; i++) {
      b = b.push('第 $i 步');
    }
    expect(b.lines.any((l) => l.kind == BroadcastKind.warning), isTrue,
        reason: '人走开一会儿回来，最该看见的就是那条警告；'
            '被 8 句流水账挤掉的话，等于没报过');
  });

  test('挤不掉的只有警告，判断类照常滚走——否则栏里全是它', () {
    var b = AgentBroadcast.empty.push('改主意了', kind: BroadcastKind.judgement);
    for (var i = 0; i < 8; i++) {
      b = b.push('第 $i 步');
    }
    expect(b.lines.any((l) => l.kind == BroadcastKind.judgement), isFalse);
  });

  test('警告攒多了也不能占满整条栏', () {
    var b = AgentBroadcast.empty;
    for (var i = 0; i < 8; i++) {
      b = b.push('问题 $i', kind: BroadcastKind.warning);
    }
    expect(b.lines.length, AgentBroadcast.maxLines);
    expect(b.lines.last.text, '问题 7', reason: '最新的那条必须在');
  });
}
