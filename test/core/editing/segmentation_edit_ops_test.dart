import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/editing/segmentation_edit_ops.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

const fps = 30.0;

List<SemanticUnit> fixture() => const [
      SemanticUnit(index: 0, startMs: 0, endMs: 6000, transcript: '第一段台词。', shots: [
        Shot(startMs: 0, endMs: 3000),
        Shot(startMs: 3000, endMs: 6000),
      ]),
      SemanticUnit(index: 1, startMs: 6000, endMs: 12000, transcript: '第二段台词。', shots: [
        Shot(startMs: 6000, endMs: 9000),
        Shot(startMs: 9000, endMs: 12000),
      ]),
    ];

void main() {
  test('不变量校验器认可合法结构、拒绝非法结构', () {
    expect(SegmentationEditOps.holdsInvariants(fixture(), 12000, fps), true);
    final broken = [
      fixture()[0].copyWith(shots: const [Shot(startMs: 0, endMs: 5000)]),
      fixture()[1],
    ];
    expect(SegmentationEditOps.holdsInvariants(broken, 12000, fps), false);
  });

  group('moveUnitBoundary', () {
    test('移动到帧点并保持不变量，原对象未被修改', () {
      final units = fixture();
      final out = SegmentationEditOps.moveUnitBoundary(units, 0, 7000, fps: fps)!;
      expect(out[0].endMs, 7000);
      expect(out[1].startMs, 7000);
      expect(out[0].shots.last.endMs, 7000);
      expect(out[1].shots.first.startMs, 7000);
      expect(SegmentationEditOps.holdsInvariants(out, 12000, fps), true);
      expect(units[0].endMs, 6000); // 不可变
    });

    test('非帧点输入被帧对齐', () {
      final out = SegmentationEditOps.moveUnitBoundary(fixture(), 0, 7010, fps: fps)!;
      expect(out[0].endMs, 7000); // 7010→帧 210→7000
    });

    test('越过右单元内部镜头边界时吞并该镜头', () {
      // 边界推到 10000：右单元原镜头 [6000,9000] 被吞，剩 [10000,12000]
      final out = SegmentationEditOps.moveUnitBoundary(fixture(), 0, 10000, fps: fps)!;
      expect(out[1].shots.length, 1);
      expect(out[1].shots.single.startMs, 10000);
      expect(out[0].shots.last.endMs, 10000);
      expect(SegmentationEditOps.holdsInvariants(out, 12000, fps), true);
    });

    test('clamp：不能把单元压到小于一帧', () {
      final out = SegmentationEditOps.moveUnitBoundary(fixture(), 0, 0, fps: fps)!;
      expect(out[0].endMs, greaterThanOrEqualTo(SegmentationEditOps.frameMs(fps)));
    });

    test('末尾边界索引非法返回 null', () {
      expect(SegmentationEditOps.moveUnitBoundary(fixture(), 1, 7000, fps: fps), isNull);
    });
  });

  group('moveShotBoundary', () {
    test('镜头边界只在两镜头间移动且帧对齐', () {
      final out = SegmentationEditOps.moveShotBoundary(fixture(), 0, 0, 4000, fps: fps)!;
      expect(out[0].shots[0].endMs, 4000);
      expect(out[0].shots[1].startMs, 4000);
      expect(SegmentationEditOps.holdsInvariants(out, 12000, fps), true);
    });

    test('clamp 在相邻镜头内部（不吞并镜头）', () {
      final out = SegmentationEditOps.moveShotBoundary(fixture(), 0, 0, 5990, fps: fps)!;
      expect(out[0].shots[1].endMs - out[0].shots[1].startMs,
          greaterThanOrEqualTo(SegmentationEditOps.frameMs(fps)));
    });
  });

  group('splitUnitAt / mergeUnitWithPrevious', () {
    const sentences = [
      AsrSentence(startMs: 0, endMs: 2900, text: '第一句。'),
      AsrSentence(startMs: 3100, endMs: 5900, text: '第二句。'),
      AsrSentence(startMs: 6100, endMs: 11900, text: '第三句。'),
    ];

    test('拆分：镜头切开、台词按句子分配、index 重排', () {
      final out = SegmentationEditOps.splitUnitAt(fixture(), 0, 3000,
          fps: fps, sentences: sentences)!;
      expect(out.length, 3);
      expect(out[0].endMs, 3000);
      expect(out[0].transcript, '第一句。');
      expect(out[1].startMs, 3000);
      expect(out[1].transcript, '第二句。');
      expect(out.map((u) => u.index).toList(), [0, 1, 2]);
      expect(SegmentationEditOps.holdsInvariants(out, 12000, fps), true);
    });

    test('拆分点在镜头内部时该镜头一分为二', () {
      final out = SegmentationEditOps.splitUnitAt(fixture(), 0, 1500,
          fps: fps, sentences: sentences)!;
      expect(out[0].shots.single.endMs, 1500);
      expect(out[1].shots.first.startMs, 1500);
      expect(out[1].shots.first.endMs, 3000);
    });

    test('拆分点贴单元边界（不足一帧）返回 null', () {
      expect(
          SegmentationEditOps.splitUnitAt(fixture(), 0, 10,
              fps: fps, sentences: sentences),
          isNull);
    });

    test('合并：镜头拼接且原边界保留为镜头边界、台词拼接', () {
      final out = SegmentationEditOps.mergeUnitWithPrevious(fixture(), 1)!;
      expect(out.length, 1);
      expect(out.single.shots.length, 4);
      expect(out.single.shots[1].endMs, 6000);
      expect(out.single.shots[2].startMs, 6000);
      expect(out.single.transcript, '第一段台词。第二段台词。');
      expect(SegmentationEditOps.holdsInvariants(out, 12000, fps), true);
    });

    test('合并首单元返回 null', () {
      expect(SegmentationEditOps.mergeUnitWithPrevious(fixture(), 0), isNull);
    });
  });

  group('splitShotAt / mergeShotWithPrevious', () {
    test('镜头拆分保持单元边界不动', () {
      final out = SegmentationEditOps.splitShotAt(fixture(), 0, 1500, fps: fps)!;
      expect(out[0].shots.length, 3);
      expect(out[0].shots[0].endMs, 1500);
      expect(out[0].startMs, 0);
      expect(out[0].endMs, 6000);
      expect(SegmentationEditOps.holdsInvariants(out, 12000, fps), true);
    });

    test('镜头合并保留标签并集', () {
      final tagged = [
        fixture()[0].copyWith(shots: const [
          Shot(startMs: 0, endMs: 3000, tags: ['A']),
          Shot(startMs: 3000, endMs: 6000, tags: ['B']),
        ]),
        fixture()[1],
      ];
      final out = SegmentationEditOps.mergeShotWithPrevious(tagged, 0, 1)!;
      expect(out[0].shots.single.tags.toSet(), {'A', 'B'});
      expect(out[0].shots.single.startMs, 0);
      expect(out[0].shots.single.endMs, 6000);
    });

    test('合并单元内首镜头返回 null', () {
      expect(SegmentationEditOps.mergeShotWithPrevious(fixture(), 0, 0), isNull);
    });
  });

  test('updateTranscript 只改文本', () {
    final out = SegmentationEditOps.updateTranscript(fixture(), 0, '新台词');
    expect(out[0].transcript, '新台词');
    expect(out[0].shots, fixture()[0].shots);
  });

  group('帧网格非等距回归（30fps 帧点间距在 33/34ms 间交替）', () {
    // 30fps 帧点：0,33,67,100,133,167,200...；clamp 若用 ms 域常数偏移
    // （如 start+33）而非帧序号域算术，算出的边界可能落在网格之外。
    List<SemanticUnit> gridFixture() => const [
          SemanticUnit(index: 0, startMs: 0, endMs: 33, transcript: 'A', shots: [
            Shot(startMs: 0, endMs: 33),
          ]),
          SemanticUnit(index: 1, startMs: 33, endMs: 67, transcript: 'B', shots: [
            Shot(startMs: 33, endMs: 67),
          ]),
          SemanticUnit(index: 2, startMs: 67, endMs: 200, transcript: 'C', shots: [
            Shot(startMs: 67, endMs: 200),
          ]),
        ];

    test('moveUnitBoundary 在非 100ms 倍数网格上 clamp 结果仍是合法帧点', () {
      final out = SegmentationEditOps.moveUnitBoundary(gridFixture(), 1, 0, fps: fps)!;
      expect(SegmentationEditOps.holdsInvariants(out, 200, fps), true);
    });

    test('moveShotBoundary 在非 100ms 倍数网格上 clamp 结果仍是合法帧点', () {
      final units = [
        const SemanticUnit(index: 0, startMs: 0, endMs: 200, transcript: 'A', shots: [
          Shot(startMs: 0, endMs: 33),
          Shot(startMs: 33, endMs: 67),
          Shot(startMs: 67, endMs: 200),
        ]),
      ];
      final out = SegmentationEditOps.moveShotBoundary(units, 0, 1, 0, fps: fps)!;
      expect(SegmentationEditOps.holdsInvariants(out, 200, fps), true);
    });
  });
}
