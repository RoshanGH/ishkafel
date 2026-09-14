import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

void main() {
  const unit = SemanticUnit(
    index: 0,
    startMs: 0,
    endMs: 9000,
    transcript: '衣服洗完还是有异味？',
    tags: ['痛点引入'],
    shots: [
      Shot(startMs: 0, endMs: 4000),
      Shot(startMs: 4000, endMs: 9000),
    ],
  );

  test('Shot 序列化往返一致', () {
    const shot = Shot(startMs: 100, endMs: 2500);
    expect(Shot.fromJson(shot.toJson()), shot);
    expect(shot.durationMs, 2400);
  });

  test('SemanticUnit 序列化往返一致（含 tags 与 shots）', () {
    expect(SemanticUnit.fromJson(unit.toJson()), unit);
    expect(unit.durationMs, 9000);
  });

  test('shotsStrictlyNested 校验严格包含', () {
    expect(unit.shotsStrictlyNested, true);
    final leaky = unit.copyWith(shots: const [Shot(startMs: 0, endMs: 9500)]);
    expect(leaky.shotsStrictlyNested, false);
  });

  test('copyWith 返回新对象且不改原对象', () {
    final renamed = unit.copyWith(transcript: '改写后的台词');
    expect(renamed.transcript, '改写后的台词');
    expect(unit.transcript, '衣服洗完还是有异味？');
    expect(identical(renamed, unit), false);
    expect(renamed.shots, unit.shots);
  });

  test('深度相等：内容相同的两个实例相等', () {
    final copy = SemanticUnit.fromJson(unit.toJson());
    expect(copy == unit, true);
    expect(copy.hashCode, unit.hashCode);
  });

  test('Shot.tags 序列化往返且旧 JSON 兼容', () {
    const tagged = Shot(startMs: 0, endMs: 1000, tags: ['产品特写']);
    expect(Shot.fromJson(tagged.toJson()), tagged);
    final legacy = Shot.fromJson(const {'startMs': 0, 'endMs': 1000});
    expect(legacy.tags, isEmpty);
    expect(legacy == const Shot(startMs: 0, endMs: 1000), true);
  });

  test('SemanticUnit.fromJson 缺 tags/shots 时兜底为空列表（与 Shot 同款兼容）', () {
    final legacy = SemanticUnit.fromJson(const {
      'index': 0,
      'startMs': 0,
      'endMs': 1000,
      'transcript': '旧版本写入的单元',
    });
    expect(legacy.tags, isEmpty);
    expect(legacy.shots, isEmpty);
  });

  test('SemanticUnit.fromJson 的 tags/shots 显式为 null 时同样兜底', () {
    final unitWithNulls = SemanticUnit.fromJson(const {
      'index': 1,
      'startMs': 0,
      'endMs': 1000,
      'transcript': 't',
      'tags': null,
      'shots': null,
    });
    expect(unitWithNulls.tags, isEmpty);
    expect(unitWithNulls.shots, isEmpty);
  });

  test('Shot.copyWith 不改原对象', () {
    const shot = Shot(startMs: 0, endMs: 1000);
    final tagged = shot.copyWith(tags: ['使用动作']);
    expect(tagged.tags, ['使用动作']);
    expect(shot.tags, isEmpty);
    expect(tagged.startMs, 0);
  });

  group('底片：这些镜头是按谁切出来的', () {
    test('存档往返：固定过的底片要带得住', () {
      const unit = SemanticUnit(
        uid: 'u1',
        index: 1,
        startMs: 4000,
        endMs: 10000,
        transcript: '',
        hasSource: false,
        baseCandidateId: 7,
        shots: [Shot(startMs: 4000, endMs: 6500)],
      );

      final back = SemanticUnit.fromJson(unit.toJson());

      expect(back.baseCandidateId, 7);
    });

    test('老存档没有这个字段：读出来是 null，就是「按原片切的」', () {
      final back = SemanticUnit.fromJson(const {
        'index': 0,
        'startMs': 0,
        'endMs': 4000,
        'transcript': '一句台词',
      });

      expect(back.baseCandidateId, isNull);
    });

    test('没固定过就不写进存档：null 和「按原片切的」是同一件事', () {
      const unit = SemanticUnit(
          index: 0, startMs: 0, endMs: 4000, transcript: '一句台词');

      expect(unit.toJson().containsKey('baseCandidateId'), isFalse);
    });

    test('底片换了就是另一个单元——不比这一项，界面会判成「没变」而不刷新',
        () {
      const a = SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 4000,
          transcript: '',
          baseCandidateId: 7);
      const b = SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 4000,
          transcript: '',
          baseCandidateId: 8);

      expect(a == b, isFalse);
      expect(a.hashCode == b.hashCode, isFalse);
    });
  });
}
