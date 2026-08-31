import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// `script extract` 从参考片整片提取时，**每行的 `reference.videoPath`
/// 按设计就是 null**——它回落到文档级的 `ScriptDoc.refVideoPath`
/// （行级那个字段只给「手动给某一行单独传一张参考」用，见 LineRef 的注释）。
///
/// 界面一直是这么读的（`line.reference?.videoPath ?? _doc.refVideoPath`），
/// 而 CLI 三处直接读 `reference?.videoPath` 就完事——于是**凡是用
/// `script extract` 建出来的脚本，tag-ref / frames / shots 一律说
/// 「手写的脚本没有参考镜」**。
///
/// 后果比报错本身重得多：那句话把人往「你这是手写脚本」上引，而实际是
/// 「参考片就在那儿，只是我没去文档上找」。验收 Agent 照着这句话去重装
/// CLI、删任务、重建任务，白跑一轮，还删掉了已经花钱生成过配音的任务。
///
/// 取法收敛成 [ScriptDoc.refVideoOf] 一处，谁都别再自己拼一遍。
void main() {
  final line = ScriptLine.create(
    text: '早就跟你们说了',
    reference: LineRef(startMs: 0, endMs: 1600),
  );

  test('整片提取的行：行级为空时回落到文档级参考片', () {
    final doc = ScriptDoc([line], refVideoPath: '/片/原片.mp4');
    expect(doc.refVideoOf(doc.lines.first), '/片/原片.mp4',
        reason: 'script extract 写的就是这种形状——行级 null、文档级有值。'
            '读不到它，整条参考片复刻在命令行上从第一步就断了');
  });

  test('行级单独传过参考的行：行级优先', () {
    final own = ScriptLine.create(
      text: '这一句我另外传了参考',
      reference: LineRef(startMs: 0, endMs: 900, videoPath: '/片/单独.mp4'),
    );
    final doc = ScriptDoc([own], refVideoPath: '/片/原片.mp4');
    expect(doc.refVideoOf(doc.lines.first), '/片/单独.mp4');
  });

  test('手写脚本：两级都没有才是真的没有参考片', () {
    final doc = ScriptDoc([ScriptLine.create(text: '手写的')]);
    expect(doc.refVideoOf(doc.lines.first), isNull);
  });
}
