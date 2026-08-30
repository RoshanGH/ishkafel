import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/frame_check.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/shot_frame_check.dart';

/// 编导台挑素材那一刻，素材本体还没下载——只有一条签名地址。
/// 但**挑中即下载**（进入方案的都要钉死），落地之后就能抽帧看了。
///
/// 时长回填走的就是这个时机（「文件都在本地了，量一下几十毫秒的事，
/// 没有必要继续猜」）。画面自查是同一类事：能看清的时候就该看，
/// 而不是让人拿到成片才发现素材上烧着别家的字。
void main() {
  LineShot shot(int id, {int? frames, String? local}) => LineShot(
      materialId: id, name: 'm$id', framesSeen: frames, localSource: local,
      burnedText: frames == null ? null : const []);

  ScriptDoc docWith(List<LineShot> shots) => ScriptDoc([
        ScriptLine(id: 'l1', text: '一句台词', shots: shots),
      ]);

  test('挑出还没看过、且已经落到本地的那几条', () {
    final todo = shotsNeedingFrameCheck(
      doc: docWith([shot(1), shot(2, frames: 3), shot(3)]),
      localPathOf: (id) => id == 3 ? null : '/local/$id.mp4',
    );
    expect(todo.map((s) => s.materialId), [1],
        reason: '2 看全了、3 还没落地');
  });

  test('参考片截的那种不查——画面就是原片自己的', () {
    final todo = shotsNeedingFrameCheck(
      doc: docWith([shot(-1, local: '/v/ref.mp4')]),
      localPathOf: (_) => '/v/ref.mp4',
    );
    expect(todo, isEmpty);
  });

  test('只看过一帧的要补看——一帧漏报产品露出', () {
    final todo = shotsNeedingFrameCheck(
      doc: docWith([shot(1, frames: 1)]),
      localPathOf: (id) => '/local/$id.mp4',
    );
    expect(todo.map((s) => s.materialId), [1]);
  });

  test('同一条素材配给好几句台词时只列一次', () {
    final doc = ScriptDoc([
      ScriptLine(id: 'l1', text: 'a', shots: [shot(7)]),
      ScriptLine(id: 'l2', text: 'b', shots: [shot(7)]),
    ]);
    final todo = shotsNeedingFrameCheck(
        doc: doc, localPathOf: (id) => '/local/$id.mp4');
    expect(todo.length, 1, reason: '查两次是白花两份钱');
  });

  test('把结果写回文档——每一句用到它的台词都要更新', () {
    final doc = ScriptDoc([
      ScriptLine(id: 'l1', text: 'a', shots: [shot(7)]),
      ScriptLine(id: 'l2', text: 'b', shots: [shot(7), shot(8)]),
    ]);
    final next = doc.withFrameCheck(
        7, const FrameCheck(burnedText: ['已售罄'], framesSeen: 3));
    expect(next.lines[0].shots[0].burnedText, ['已售罄']);
    expect(next.lines[1].shots[0].burnedText, ['已售罄']);
    expect(next.lines[1].shots[1].burnedText, isNull, reason: '别串到别的素材上');
  });

  test('写回结果不弄丢别的字段', () {
    const full = LineShot(
        materialId: 7, name: 'm', trimStartMs: 500, speed: 1.5, allocMs: 3000);
    final next = ScriptDoc([
      ScriptLine(id: 'l1', text: 'a', shots: [full]),
    ]).withFrameCheck(7, const FrameCheck(framesSeen: 3));
    final after = next.lines[0].shots[0];
    expect(after.trimStartMs, 500);
    expect(after.speed, 1.5);
    expect(after.allocMs, 3000);
  });
}
