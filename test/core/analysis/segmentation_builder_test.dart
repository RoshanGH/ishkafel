import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';

void main() {
  const builder = SegmentationBuilder();

  test('两个草稿单元：内部边界吸附到最近镜头边界', () {
    final units = builder.build(
      drafts: const [
        UnitDraft(startMs: 0, endMs: 9200, transcript: '第一段'),
        UnitDraft(startMs: 9200, endMs: 20000, transcript: '第二段'),
      ],
      shotBoundaryMs: [4000, 9000, 14000],
      silenceValleyMs: const [],
      videoDurationMs: 20000,
      fps: 30,
    );
    expect(units.length, 2);
    expect(units[0].startMs, 0);
    expect(units[0].endMs, 9000); // 9200 吸附到镜头边界 9000（30fps 下 9000 恰为帧点）
    expect(units[1].startMs, 9000);
    expect(units[1].endMs, 20000);
  });

  test('每单元的镜头分割覆盖全单元且严格嵌套', () {
    final units = builder.build(
      drafts: const [
        UnitDraft(startMs: 0, endMs: 9200, transcript: 'A'),
        UnitDraft(startMs: 9200, endMs: 20000, transcript: 'B'),
      ],
      shotBoundaryMs: [4000, 9000, 14000],
      silenceValleyMs: const [],
      videoDurationMs: 20000,
      fps: 30,
    );
    for (final u in units) {
      expect(u.shotsStrictlyNested, true);
      expect(u.shots.first.startMs, u.startMs); // 单元边界即镜头边界
      expect(u.shots.last.endMs, u.endMs);
      for (var k = 0; k < u.shots.length - 1; k++) {
        expect(u.shots[k].endMs, u.shots[k + 1].startMs); // 无缝覆盖
      }
    }
    expect(units[0].shots.length, 2); // [0,4000][4000,9000]
    expect(units[1].shots.length, 2); // [9000,14000][14000,20000]
  });

  test('单元内无镜头边界时整单元为一个镜头', () {
    final units = builder.build(
      drafts: const [UnitDraft(startMs: 0, endMs: 5000, transcript: 'X')],
      shotBoundaryMs: const [],
      silenceValleyMs: const [],
      videoDurationMs: 5000,
      fps: 30,
    );
    expect(units.single.shots.single.startMs, 0);
    expect(units.single.shots.single.endMs, 5000);
  });

  test('吸附导致边界越过前一边界时回退为原位帧对齐', () {
    final units = builder.build(
      drafts: const [
        UnitDraft(startMs: 0, endMs: 300, transcript: 'A'),
        UnitDraft(startMs: 300, endMs: 2000, transcript: 'B'),
      ],
      // 镜头边界 0 在窗口(600ms)内且比 300 更近 0 侧 → 若直接吸附会得到 0，越过起点
      shotBoundaryMs: const [0],
      silenceValleyMs: const [],
      videoDurationMs: 2000,
      fps: 30,
    );
    expect(units[0].endMs, greaterThan(units[0].startMs));
    expect(units[1].endMs, 2000);
  });

  test('空草稿返回空', () {
    expect(
      builder.build(
        drafts: const [],
        shotBoundaryMs: const [],
        silenceValleyMs: const [],
        videoDurationMs: 1000,
        fps: 30,
      ),
      isEmpty,
    );
  });

  test('镜头边界未预帧对齐时不应产出毫秒级 sliver shot', () {
    // shotBoundaryMs=2703 在 30fps 下帧对齐值为 2700；若 inner 分割仍用原始
    // 2703 而单元边界用吸附后的 2700，会产出 [2700,2703] 这类毫秒级镜头，
    // 且该边界不满足「所有切点帧对齐」约束。
    final units = builder.build(
      drafts: const [
        UnitDraft(startMs: 0, endMs: 2750, transcript: 'A'),
        UnitDraft(startMs: 2750, endMs: 6000, transcript: 'B'),
      ],
      shotBoundaryMs: const [2703],
      silenceValleyMs: const [],
      videoDurationMs: 6000,
      fps: 30,
    );
    const fps = 30.0;
    const frameWidthMs = 1000 / fps; // ≈33.33ms
    for (final u in units) {
      for (final s in u.shots) {
        expect(s.durationMs, greaterThan(frameWidthMs),
            reason: 'shot ${s.startMs}-${s.endMs} 不应短于一帧');
        expect(builder.snapper.snapToFrame(s.startMs, fps), s.startMs,
            reason: '${s.startMs} 应帧对齐');
        expect(builder.snapper.snapToFrame(s.endMs, fps), s.endMs,
            reason: '${s.endMs} 应帧对齐');
      }
    }
  });

  test('draft.endMs 逼近片长时内部边界应夹紧，避免零/负时长单元', () {
    // draft0.endMs=990 在 30fps 下帧对齐会四舍五入到 1000（与片长相同），
    // 若不夹紧，会产出 start=1000,end=1000 的零时长单元。
    final units = builder.build(
      drafts: const [
        UnitDraft(startMs: 0, endMs: 990, transcript: 'A'),
        UnitDraft(startMs: 990, endMs: 1000, transcript: 'B'),
      ],
      shotBoundaryMs: const [],
      silenceValleyMs: const [],
      videoDurationMs: 1000,
      fps: 30,
    );
    expect(units.length, 2);
    for (final u in units) {
      expect(u.durationMs, greaterThan(0));
    }
    for (var i = 0; i < units.length - 1; i++) {
      expect(units[i].endMs, lessThan(units[i + 1].endMs));
      expect(units[i].endMs, units[i + 1].startMs);
    }
    expect(units.last.endMs, 1000);
  });

  test('两次回退仍越界时强制递增一帧宽度（Task 8 遗留分支）', () {
    // draft0.endMs=300 与 draft1.endMs=310 在 30fps 下帧对齐均落到 300，
    // 吸附与原位回退都 <= 上一边界，触发「强制 +1 帧宽度」分支。
    final units = builder.build(
      drafts: const [
        UnitDraft(startMs: 0, endMs: 300, transcript: 'A'),
        UnitDraft(startMs: 300, endMs: 310, transcript: 'B'),
        UnitDraft(startMs: 310, endMs: 1000, transcript: 'C'),
      ],
      shotBoundaryMs: const [],
      silenceValleyMs: const [],
      videoDurationMs: 1000,
      fps: 30,
    );
    expect(units.length, 3);
    expect(units[0].endMs, 300);
    expect(units[1].startMs, 300);
    expect(units[1].endMs, 333); // 300 + round(1000/30)
    expect(units[2].startMs, 333);
    expect(units[2].endMs, 1000);
    for (final u in units) {
      expect(u.durationMs, greaterThan(0));
    }
  });

  test('index 按顺序编号', () {
    final units = builder.build(
      drafts: const [
        UnitDraft(startMs: 0, endMs: 1000, transcript: 'A'),
        UnitDraft(startMs: 1000, endMs: 2000, transcript: 'B'),
        UnitDraft(startMs: 2000, endMs: 3000, transcript: 'C'),
      ],
      shotBoundaryMs: const [],
      silenceValleyMs: const [],
      videoDurationMs: 3000,
      fps: 30,
    );
    expect(units.map((u) => u.index).toList(), [0, 1, 2]);
  });
}
