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
      // 台词与 ASR 重建文本一致（未被手工改过）时才走"按句子分配"这条路：
      // 单元 0 覆盖 sentences[0]+sentences[1]，其拼接即为该单元台词
      final units = [
        fixture()[0].copyWith(transcript: '第一句。第二句。'),
        fixture()[1].copyWith(transcript: '第三句。'),
      ];
      final out = SegmentationEditOps.splitUnitAt(units, 0, 3000,
          fps: fps, sentences: sentences)!;
      expect(out.length, 3);
      expect(out[0].endMs, 3000);
      expect(out[0].transcript, '第一句。');
      expect(out[1].startMs, 3000);
      expect(out[1].transcript, '第二句。');
      expect(out.map((u) => u.index).toList(), [0, 1, 2]);
      expect(SegmentationEditOps.holdsInvariants(out, 12000, fps), true);
    });

    group('拆分不得静默丢弃单元现有台词（评审 Critical 1）', () {
      test('sentences 为空时不清空台词：两段拼接仍等于原台词', () {
        final out = SegmentationEditOps.splitUnitAt(fixture(), 0, 3000,
            fps: fps, sentences: const [])!;
        expect(out[0].transcript, isNotEmpty);
        expect(out[1].transcript, isNotEmpty);
        expect(out[0].transcript + out[1].transcript, '第一段台词。');
      });

      test('台词被手工改过（与 ASR 重建文本不一致）时按比例切现有台词，不还原成 ASR 原文', () {
        final edited = [
          fixture()[0].copyWith(transcript: '手工改过的台词甲乙'),
          fixture()[1],
        ];
        final out = SegmentationEditOps.splitUnitAt(edited, 0, 3000,
            fps: fps, sentences: sentences)!;
        expect(out[0].transcript + out[1].transcript, '手工改过的台词甲乙');
        expect(out[0].transcript, isNot(contains('第一句')));
        expect(out[1].transcript, isNot(contains('第二句')));
      });

      test('拆分再合并回来，台词逐字复原（左右两段拼接无损）', () {
        final split = SegmentationEditOps.splitUnitAt(fixture(), 0, 4500,
            fps: fps, sentences: const [])!;
        final merged = SegmentationEditOps.mergeUnitWithPrevious(split, 1)!;
        expect(merged[0].transcript, '第一段台词。');
      });
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
      final out = SegmentationEditOps.splitShotAt(fixture(), 0, 1500,
          fps: fps, shotIndex: 0)!;
      expect(out[0].shots.length, 3);
      expect(out[0].shots[0].endMs, 1500);
      expect(out[0].startMs, 0);
      expect(out[0].endMs, 6000);
      expect(SegmentationEditOps.holdsInvariants(out, 12000, fps), true);
    });

    group('只拆指定的那个镜头（Critical 2）', () {
      test('拆分点落在别的镜头内 → 返回 null，绝不改拆别的镜头', () {
        // shotIndex=0 是 [0,3000]，拆分点 4500 落在镜头 1 内
        expect(
            SegmentationEditOps.splitShotAt(fixture(), 0, 4500,
                fps: fps, shotIndex: 0),
            isNull);
      });

      test('拆分点贴指定镜头边界（两侧留不出一帧）→ 返回 null', () {
        expect(
            SegmentationEditOps.splitShotAt(fixture(), 0, 10,
                fps: fps, shotIndex: 0),
            isNull);
        expect(
            SegmentationEditOps.splitShotAt(fixture(), 0, 3000,
                fps: fps, shotIndex: 0),
            isNull);
      });

      test('shotIndex 越界 → 返回 null', () {
        expect(
            SegmentationEditOps.splitShotAt(fixture(), 0, 1500,
                fps: fps, shotIndex: 9),
            isNull);
        expect(
            SegmentationEditOps.splitShotAt(fixture(), 0, 1500,
                fps: fps, shotIndex: -1),
            isNull);
      });

      test('拆分点落在指定镜头内 → 只有该镜头被一分为二，标签继承', () {
        final tagged = [
          fixture()[0].copyWith(shots: const [
            Shot(startMs: 0, endMs: 3000, tags: ['A']),
            Shot(startMs: 3000, endMs: 6000, tags: ['B']),
          ]),
          fixture()[1],
        ];
        final out = SegmentationEditOps.splitShotAt(tagged, 0, 4500,
            fps: fps, shotIndex: 1)!;
        expect(out[0].shots.length, 3);
        expect(out[0].shots[0], tagged[0].shots[0], reason: '镜头 0 不受影响');
        expect(out[0].shots[1].endMs, 4500);
        expect(out[0].shots[2].startMs, 4500);
        expect(out[0].shots[2].tags, ['B']);
        expect(SegmentationEditOps.holdsInvariants(out, 12000, fps), true);
      });
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
            // maxB 落在末单元的末镜头（下标 1）内
            out = SegmentationEditOps.splitShotAt(fixtureFor(d), 1, maxB,
                fps: fps, shotIndex: 1);
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

  group('一帧的真实最小跨度（Critical 3：帧率非 30 时误判合法片段为非法）', () {
    // frameMs(fps)=round(1000/fps) 只是"标称帧时长"，与帧点在毫秒轴上的真实
    // 相邻间距未必相等：
    // - 30fps：round=33，帧点 0,33,67,100…，最小间距也是 33 → 恰好安全
    // - 24fps：round=42，帧点 0,42,83,125…，最小间距 41 → 差 1ms
    // - 60fps：round=17，帧点 …,967,983,1000…，最小间距 16 → 差 1ms
    // 于是 24/60fps 素材下，恰好跨一帧的合法片段会被 holdsInvariants 判为
    // 非法，clamp 也被迫多留一帧。

    test('minFrameSpanMs 给出相邻帧点的真实最小间距（覆盖常见帧率）', () {
      const expected = <(double, int)>[
        (23.976, 41),
        (24.0, 41),
        (25.0, 40),
        (29.97, 33),
        (30.0, 33),
        (50.0, 20),
        (59.94, 16),
        (60.0, 16),
      ];
      for (final (rate, span) in expected) {
        expect(SegmentationEditOps.minFrameSpanMs(rate), span, reason: 'fps=$rate');
      }
    });

    test('30fps 行为完全不变：真实最小间距恰等于标称帧时长 33ms', () {
      expect(SegmentationEditOps.minFrameSpanMs(30), 33);
      expect(SegmentationEditOps.minFrameSpanMs(30), SegmentationEditOps.frameMs(30));
    });

    test('60fps：跨一帧的片段（967→983，16ms）是合法结构', () {
      // 60fps 帧点：58→967、59→983、60→1000、120→2000
      final units = [
        const SemanticUnit(index: 0, startMs: 0, endMs: 967, transcript: 'A', shots: [
          Shot(startMs: 0, endMs: 967),
        ]),
        const SemanticUnit(index: 1, startMs: 967, endMs: 983, transcript: 'B', shots: [
          Shot(startMs: 967, endMs: 983),
        ]),
        const SemanticUnit(index: 2, startMs: 983, endMs: 2000, transcript: 'C', shots: [
          Shot(startMs: 983, endMs: 2000),
        ]),
      ];
      expect(SegmentationEditOps.holdsInvariants(units, 2000, 60), true);
    });

    test('24fps：跨一帧的片段（42→83，41ms）是合法结构', () {
      // 24fps 帧点：1→42、2→83、24→1000
      final units = [
        const SemanticUnit(index: 0, startMs: 0, endMs: 42, transcript: 'A', shots: [
          Shot(startMs: 0, endMs: 42),
        ]),
        const SemanticUnit(index: 1, startMs: 42, endMs: 83, transcript: 'B', shots: [
          Shot(startMs: 42, endMs: 83),
        ]),
        const SemanticUnit(index: 2, startMs: 83, endMs: 1000, transcript: 'C', shots: [
          Shot(startMs: 83, endMs: 1000),
        ]),
      ];
      expect(SegmentationEditOps.holdsInvariants(units, 1000, 24), true);
    });

    test('60fps：镜头边界推到极右可达 967（退让真实一帧 16ms），不再被迫多退一帧到 950', () {
      // 末镜头 endMs=983（帧点 59）：真实上界是 967（983-967=16=一帧），
      // 旧实现按 17ms 计算退让幅度，只能停在 950（多退了一整帧）
      final units = [
        const SemanticUnit(index: 0, startMs: 0, endMs: 983, transcript: 'A', shots: [
          Shot(startMs: 0, endMs: 500),
          Shot(startMs: 500, endMs: 983),
        ]),
      ];
      final out = SegmentationEditOps.moveShotBoundary(units, 0, 0, 999999, fps: 60)!;
      expect(out[0].shots[0].endMs, 967);
      expect(SegmentationEditOps.holdsInvariants(out, 983, 60), true);
    });

    test('60fps：拆分点可落在距镜头末端一帧处（967），不再被拒', () {
      final units = [
        const SemanticUnit(index: 0, startMs: 0, endMs: 983, transcript: 'A', shots: [
          Shot(startMs: 0, endMs: 983),
        ]),
      ];
      final out = SegmentationEditOps.splitShotAt(units, 0, 967, fps: 60, shotIndex: 0)!;
      expect(out[0].shots.length, 2);
      expect(out[0].shots[1].startMs, 967);
      expect(SegmentationEditOps.holdsInvariants(out, 983, 60), true);
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
      final out = SegmentationEditOps.splitShotAt(tightFixture(), 1, 999999,
          fps: fps, shotIndex: 0);
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
