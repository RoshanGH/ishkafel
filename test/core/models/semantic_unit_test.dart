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
}
