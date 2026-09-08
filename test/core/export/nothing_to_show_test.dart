import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

SemanticUnit _u(int index, {bool hasSource = true}) => SemanticUnit(
      index: index,
      startMs: index * 1000,
      endMs: (index + 1) * 1000,
      transcript: 'U${index + 1}',
      hasSource: hasSource,
    );

void main() {
  group('手动加的单元没挑素材＝真的没东西可放', () {
    test('点名是哪几个单元，不静默放过', () {
      final units = [_u(0), _u(1, hasSource: false)];

      expect(unitsWithNothingToShow(units, const []), [1],
          reason: '原片上没有 U2，又没挑素材——导出只会得到一段空白或直接崩，'
              '必须在这之前指着说是哪一个');
    });

    test('挑了素材就没问题', () {
      final units = [_u(0), _u(1, hasSource: false)];
      final plans = [
        UnitReplacement.keepOriginal(),
        UnitReplacement.whole(const [101]),
      ];

      expect(unitsWithNothingToShow(units, plans), isEmpty);
    });

    test('有原片来源的单元不挑素材照样能导（就用原片）', () {
      expect(unitsWithNothingToShow([_u(0), _u(1)], const []), isEmpty);
    });

    test('挑的是逐镜头替换也算数', () {
      final units = [_u(0, hasSource: false)];
      final plans = [
        UnitReplacement.perShot(const {
          0: [101]
        })
      ];

      expect(unitsWithNothingToShow(units, plans), isEmpty);
    });

    test('替换方案存在但一条候选都没选，等于没挑', () {
      final units = [_u(0, hasSource: false)];
      final plans = [UnitReplacement.whole(const [])];

      expect(unitsWithNothingToShow(units, plans), [0]);
    });
  });
}
