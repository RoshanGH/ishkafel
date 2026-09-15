import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/thumbs_span.dart';

/// 插入段在原片上不存在，画面轨和音频轨在那一段本来就是空的——
/// **空着不说话，人看到的是「这一大片是不是坏了」**。
///
/// 同事第一次用就问了这句（2026-09-15：「这个音频和画面轨是空的？分析完
/// 之后是不是应该补上」）。答案是不该补，那儿没有原片可放；该做的是把
/// 这件事写在那一段上（见 `TimelinePainter._paintNoSourceSpans`）。
///
/// 这组测试钉住底层那条规则：**缩略图只铺在取自原片的单元上**。
void main() {
  /// 前 3 个是插入段（拖到了最前），后 6 个取自原片
  List<SemanticUnit> mixed() {
    final units = <SemanticUnit>[];
    // 插入段：startMs/endMs 是塞在原片末尾的占位，但列表顺序在最前
    for (var i = 0; i < 3; i++) {
      units.add(SemanticUnit(
          uid: 'p$i',
          index: i,
          startMs: 102300 + i * 10000,
          endMs: 102300 + (i + 1) * 10000,
          transcript: '',
          hasSource: false));
    }
    for (var i = 0; i < 6; i++) {
      units.add(SemanticUnit(
          uid: 'u$i',
          index: 3 + i,
          startMs: i * 17050,
          endMs: (i + 1) * 17050,
          transcript: 'U$i',
          shots: [Shot(startMs: i * 17050, endMs: (i + 1) * 17050)]));
    }
    return units;
  }

  test('胶片条只按原片长度等分——插入段占的时间不算进去', () {
    expect(sourceSpanMs(mixed()), 102300,
        reason: '算进插入段的话整条胶片条会压扁，和上面的单元块全部对不齐');
  });

  test('插入段那几段一格缩略图都不铺', () {
    // 成片上：插入段占前 30s，原片单元接在后面
    const width = 900.0;
    const totalMs = 132300;
    final cells = thumbCells(
      units: mixed(),
      count: 32,
      pxOfUnit: (i) {
        // 前 3 个插入段各占 10s，其余按原片时长顺排
        if (i < 3) {
          return (i * 10000 / totalMs * width,
              (i + 1) * 10000 / totalMs * width);
        }
        final start = 30000 + (i - 3) * 17050;
        return (start / totalMs * width,
            (start + 17050) / totalMs * width);
      },
    );

    expect(cells, isNotEmpty);
    final leftmost = cells.map((c) => c.left).reduce((a, b) => a < b ? a : b);
    expect(leftmost, greaterThanOrEqualTo(30000 / totalMs * width - 0.01),
        reason: '插入段占的前 30 秒里不该有任何一格原片缩略图');
  });

  test('全是插入段（拼片）：整条胶片条不画', () {
    final blank = [
      for (var i = 0; i < 4; i++)
        SemanticUnit(
            uid: 'b$i',
            index: i,
            startMs: i * 10000,
            endMs: (i + 1) * 10000,
            transcript: '',
            hasSource: false),
    ];

    expect(sourceSpanMs(blank), 0);
    expect(
      thumbCells(units: blank, count: 32, pxOfUnit: (i) => (0, 100)),
      isEmpty,
    );
  });
}
