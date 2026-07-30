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

  group('末端边界非帧点片长回归（Critical 1：真实片长几乎必然非帧点）', () {
    // 30fps 下真实视频片长几乎必然落在帧点之外。末单元 endMs 与其末镜头
    // endMs 都恒等于 durationMs，理应被 holdsInvariants 豁免帧点检查（片长
    // 是外部数据，强行帧对齐会丢失片尾内容）；除此之外的一切边界（含首边界
    // 0、单元间边界、所有其余镜头间边界）仍必须帧对齐——且任何操作产出的
    // 结构，其末段时长仍必须 >= 1 帧（这是本组回归新增的重点：clamp 上界
    // 若只满足"帧点"而不保证"距 endMs >= 1 帧"，会在把边界推到极右时产出
    // 短于一帧的末段）。
    //
    // 七个片长覆盖三类情形（用 python 独立复算校验，见提交信息）：
    // - 3984 / 59987 / 92253：复审实测在旧实现下会触发非法结构（旧
    //   `_frameBefore` 退让幅度 20~17ms，不足一帧 33ms）
    // - 4001 / 4016 / 12345 / 75302：旧实现退让幅度恰好 >= 一帧，本就不崩，
    //   列入是为了确认修复不改变这些已经正确的既有行为
    // - 75302 与 92253 是本项目真实测试素材的实际片长
    const durations = [3984, 4001, 4016, 12345, 59987, 75302, 92253];

    List<SemanticUnit> fixtureFor(int durationMs) => [
          const SemanticUnit(
              index: 0, startMs: 0, endMs: 2000, transcript: 'A', shots: [
            Shot(startMs: 0, endMs: 1000),
            Shot(startMs: 1000, endMs: 2000),
          ]),
          SemanticUnit(
              index: 1, startMs: 2000, endMs: durationMs, transcript: 'B', shots: [
            const Shot(startMs: 2000, endMs: 3000),
            Shot(startMs: 3000, endMs: durationMs),
          ]),
        ];

    test('holdsInvariants 对非帧点片长的合法结构返回 true（对全部片长成立）', () {
      for (final d in durations) {
        expect(SegmentationEditOps.holdsInvariants(fixtureFor(d), d, fps), true,
            reason: 'durationMs=$d');
      }
    });

    for (final d in durations) {
      group('durationMs=$d', () {
        test('moveUnitBoundary 推到极右：末单元 endMs 保持、末段不短于一帧', () {
          List<SemanticUnit>? out;
          expect(() {
            out = SegmentationEditOps.moveUnitBoundary(fixtureFor(d), 0, 999999,
                fps: fps);
          }, returnsNormally);
          expect(out, isNotNull);
          expect(out![1].endMs, d);
          expect(SegmentationEditOps.holdsInvariants(out!, d, fps), true);
        });

        test('moveShotBoundary 在末单元内推到极右：末镜头 endMs 保持、末段不短于一帧',
            () {
          List<SemanticUnit>? out;
          expect(() {
            out = SegmentationEditOps.moveShotBoundary(fixtureFor(d), 1, 0, 999999,
                fps: fps);
          }, returnsNormally);
          expect(out, isNotNull);
          expect(out![1].shots.last.endMs, d);
          expect(SegmentationEditOps.holdsInvariants(out!, d, fps), true);
        });

        test('splitUnitAt 在末单元可达的最远合法点拆分：末段不短于一帧', () {
          final maxB = _expectedMaxBoundary(d, fps);
          List<SemanticUnit>? out;
          expect(() {
            out = SegmentationEditOps.splitUnitAt(fixtureFor(d), 1, maxB,
                fps: fps, sentences: const []);
          }, returnsNormally);
          expect(out, isNotNull, reason: 'maxB=$maxB 应是一个合法拆分点');
          expect(out!.last.endMs, d);
          expect(SegmentationEditOps.holdsInvariants(out!, d, fps), true);
        });

        test('splitShotAt 在末单元末镜头可达的最远合法点拆分：末段不短于一帧', () {
          final maxB = _expectedMaxBoundary(d, fps);
          List<SemanticUnit>? out;
          expect(() {
            out = SegmentationEditOps.splitShotAt(fixtureFor(d), 1, maxB, fps: fps);
          }, returnsNormally);
          expect(out, isNotNull, reason: 'maxB=$maxB 应是一个合法拆分点');
          expect(out![1].shots.last.endMs, d);
          expect(SegmentationEditOps.holdsInvariants(out!, d, fps), true);
        });

        test('mergeUnitWithPrevious 合并末单元后，合并结果 endMs 仍为 $d', () {
          List<SemanticUnit>? out;
          expect(() {
            out = SegmentationEditOps.mergeUnitWithPrevious(fixtureFor(d), 1);
          }, returnsNormally);
          expect(out, isNotNull);
          expect(out!.single.endMs, d);
          expect(SegmentationEditOps.holdsInvariants(out!, d, fps), true);
        });
      });
    }
  });

  group('clamp 上界收缩幅度不小于一帧（Critical 1 修法自检：帧点 endMs 上新旧算法一致）', () {
    // 当 endMs 本身就是合法帧点时，新的 clamp 上界算法必须与旧的
    // `_frameBefore(endMs, fps)`（单纯回退一帧）给出相同结果——因为任意
    // 两个相邻帧点间距在 30fps 下恒为 33 或 34ms，都 >= frameMs(30)=33，
    // 回退一帧天然满足"留白 >= 一帧"的约束。下列数值（67/100/4000/96233）
    // 用 python 独立复算验证过与旧 `_frameBefore` 结果一致（见提交信息），
    // 通过 moveShotBoundary 这一个调用点验证，因为四处 clamp 上界共享同一
        // 私有帮助函数。
    test('endMs=67（帧点）：推到极右夹到 33（与旧 _frameBefore 结果一致）', () {
      final units = [
        const SemanticUnit(index: 0, startMs: 0, endMs: 67, transcript: 'A', shots: [
          Shot(startMs: 0, endMs: 33),
          Shot(startMs: 33, endMs: 67),
        ]),
      ];
      final out = SegmentationEditOps.moveShotBoundary(units, 0, 0, 999999, fps: fps)!;
      expect(out[0].shots[0].endMs, 33);
      expect(SegmentationEditOps.holdsInvariants(out, 67, fps), true);
    });

    test('endMs=100（帧点）：推到极右夹到 67（与旧 _frameBefore 结果一致）', () {
      final units = [
        const SemanticUnit(
            index: 0, startMs: 0, endMs: 100, transcript: 'A', shots: [
          Shot(startMs: 0, endMs: 33),
          Shot(startMs: 33, endMs: 100),
        ]),
      ];
      final out = SegmentationEditOps.moveShotBoundary(units, 0, 0, 999999, fps: fps)!;
      expect(out[0].shots[0].endMs, 67);
      expect(SegmentationEditOps.holdsInvariants(out, 100, fps), true);
    });

    test('endMs=4000（帧点）：推到极右夹到 3967（与旧 _frameBefore 结果一致）', () {
      final units = [
        const SemanticUnit(
            index: 0, startMs: 0, endMs: 2000, transcript: 'A', shots: [
          Shot(startMs: 0, endMs: 2000),
        ]),
        const SemanticUnit(
            index: 1, startMs: 2000, endMs: 4000, transcript: 'B', shots: [
          Shot(startMs: 2000, endMs: 3000),
          Shot(startMs: 3000, endMs: 4000),
        ]),
      ];
      final out = SegmentationEditOps.moveShotBoundary(units, 1, 0, 999999, fps: fps)!;
      expect(out[1].shots[0].endMs, 3967);
      expect(SegmentationEditOps.holdsInvariants(out, 4000, fps), true);
    });

    test('endMs=96233（帧点）：推到极右夹到 96200（与旧 _frameBefore 结果一致）', () {
      final units = [
        const SemanticUnit(
            index: 0, startMs: 0, endMs: 90000, transcript: 'A', shots: [
          Shot(startMs: 0, endMs: 90000),
        ]),
        const SemanticUnit(
            index: 1, startMs: 90000, endMs: 96233, transcript: 'B', shots: [
          Shot(startMs: 90000, endMs: 93000),
          Shot(startMs: 93000, endMs: 96233),
        ]),
      ];
      final out = SegmentationEditOps.moveShotBoundary(units, 1, 0, 999999, fps: fps)!;
      expect(out[1].shots[0].endMs, 96200);
      expect(SegmentationEditOps.holdsInvariants(out, 96233, fps), true);
    });
  });

  group('边界情形：无合法移动/拆分位置时不产出非法结构（Critical 1 修法自检）', () {
    // 每个单元都恰好卡在"1 帧最小时长"上：unit0=[0,33]（帧点终点），
    // unit1=[33,73]（末单元，非帧点终点，尾段刚好 40ms，仍 >= 1 帧）——
    // 两侧都已贴着各自的最小时长下限，没有任何位置可再移动/拆分。
    List<SemanticUnit> tightFixture() => const [
          SemanticUnit(index: 0, startMs: 0, endMs: 33, transcript: 'A', shots: [
            Shot(startMs: 0, endMs: 33),
          ]),
          SemanticUnit(index: 1, startMs: 33, endMs: 73, transcript: 'B', shots: [
            Shot(startMs: 33, endMs: 73),
          ]),
        ];
    const tightDuration = 73;

    test('moveUnitBoundary 推到极右：无合法位置，边界原地不变（no-op），不产出非法结构', () {
      final out =
          SegmentationEditOps.moveUnitBoundary(tightFixture(), 0, 999999, fps: fps)!;
      expect(out[0].endMs, 33, reason: '两侧都已是最小时长，边界无法移动');
      expect(SegmentationEditOps.holdsInvariants(out, tightDuration, fps), true);
    });

    test('splitUnitAt 尝试拆分已贴最小时长的末单元：无合法拆分点，返回 null 而非非法结构', () {
      final out = SegmentationEditOps.splitUnitAt(tightFixture(), 1, 999999,
          fps: fps, sentences: const []);
      expect(out, isNull);
    });

    test('splitShotAt 尝试拆分已贴最小时长的末单元末镜头：无合法拆分点，返回 null', () {
      final out =
          SegmentationEditOps.splitShotAt(tightFixture(), 1, 999999, fps: fps);
      expect(out, isNull);
    });
  });
}

/// 与实现里 clamp 上界所用私有算法（帧序号域回退一帧，必要时回退校正）的
/// 独立测试参考实现：给定 endMs，返回"收缩后至少留一帧尾段"的最大合法帧
/// 点。仅用于在测试里独立算出各片长下拆分操作可达的最远合法拆分点（构造
/// 输入），不依赖被测实现本身的私有函数。
int _expectedMaxBoundary(int endMs, double fps) {
  final gap = SegmentationEditOps.frameMs(fps);
  final threshold = endMs - gap;
  var idx = (threshold * fps / 1000).round();
  if (idx < 0) idx = 0;
  while (idx > 0 && (idx * 1000 / fps).round() > threshold) {
    idx--;
  }
  return (idx * 1000 / fps).round();
}
