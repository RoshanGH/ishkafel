import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

void main() {
  group('替换方案序列化（要能落进任务 JSON 再原样读出来）', () {
    test('三种模式往返一致', () {
      final cases = <UnitReplacement>[
        UnitReplacement.keepOriginal(),
        UnitReplacement.whole([11, 22]),
        UnitReplacement.perShot({
          0: [1, 2],
          2: [3],
        }),
      ];
      for (final original in cases) {
        // 经过一次真正的 jsonEncode/Decode，确保没有依赖内存里的 int 键
        final decoded = jsonDecode(jsonEncode(original.toJson()));
        final parsed = UnitReplacement.tryFromJson(decoded);
        expect(parsed, original, reason: '模式 ${original.mode} 往返后必须相等');
      }
    });

    test('mode 序列化为稳定字符串（存储契约，不许改名）', () {
      expect(ReplacementMode.keepOriginal.name, 'keepOriginal');
      expect(ReplacementMode.whole.name, 'whole');
      expect(ReplacementMode.perShot.name, 'perShot');
    });

    test('镜头下标以字符串键落盘（JSON 对象的键只能是字符串）', () {
      final json = UnitReplacement.perShot({
        2: [7]
      }).toJson();
      final shots = json['shotCandidateIds'] as Map<String, dynamic>;
      expect(shots.keys, ['2']);
      expect(shots['2'], [7]);
    });

    test('未知 mode（更高版本写入的模式）回退为保留原片，不抛异常', () {
      final parsed = UnitReplacement.tryFromJson({
        'mode': 'randomPerExport',
        'wholeCandidateIds': [1],
      });
      expect(parsed, isNotNull);
      expect(parsed!.mode, ReplacementMode.keepOriginal,
          reason: '抛异常会让整条任务在列表里静默消失，这是本项目出过的事故');
    });

    test('结构畸形一律返回 null 而不是抛异常', () {
      expect(UnitReplacement.tryFromJson(null), isNull);
      expect(UnitReplacement.tryFromJson('whole'), isNull);
      expect(UnitReplacement.tryFromJson(42), isNull);
    });

    test('候选 id 里混入非整数时只跳过那一个，其余照常读出', () {
      final parsed = UnitReplacement.tryFromJson({
        'mode': 'whole',
        'wholeCandidateIds': [1, '2', null, 3],
      });
      expect(parsed!.wholeCandidateIds, [1, 3]);
    });

    test('镜头键不是整数时跳过该镜头，不牵连其他镜头', () {
      final parsed = UnitReplacement.tryFromJson({
        'mode': 'perShot',
        'shotCandidateIds': {
          '0': [1],
          'S2': [2],
        },
      });
      expect(parsed!.shotCandidateIds.keys, [0]);
    });

    test('== 按值比较（RenewTask 的深度相等依赖它）', () {
      expect(UnitReplacement.whole([1, 2]), UnitReplacement.whole([1, 2]));
      expect(UnitReplacement.whole([1, 2]) == UnitReplacement.whole([2, 1]),
          isFalse,
          reason: '候选顺序就是导出顺序，不能视为等价');
      expect(UnitReplacement.keepOriginal() == UnitReplacement.whole(const []),
          isFalse,
          reason: '两者因子都是 1，但模式不同，界面上的徽标也不同');
      expect(UnitReplacement.whole([1]).hashCode,
          UnitReplacement.whole([1]).hashCode);
    });
  });
}
