import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/script_apply_command.dart';

/// 提交回填时那份「候选清单」，手册里叫 `offered`，代码只认 `candidates`。
///
/// 后果按条线分：`apply shots` 那节正文额外说了一句「`candidates` 要原样
/// 带上」，照着做的人蒙对了；**配乐那节只说 `offered`**——于是
/// `apply bgm` 照手册写必错，而且错得莫名其妙：
///
/// ```
/// $ ishkafel script bgm-candidates <task>     → materialId 108
/// $ ishkafel script apply bgm <task> --file b.json   # offered 里就是 108
/// · 配乐 108 不在候选里。曲子要从 ishkafel script bgm-candidates 拿
/// ```
///
/// 验收 Agent 两种形状都试了（对象数组、纯 id 数组），都拒，只能放弃——
/// **交付的成片全片没有配乐**。它的第一反应是「我的 offered 形状写错了」，
/// 因为报错说的是「108 不在候选里」，而不是「你压根没给候选清单」。
///
/// 两个名字都认；同时「清单是空的」要和「这个 id 不在清单里」分开说。
void main() {
  Map<String, dynamic> bgmPayload(String fieldName) => {
        'bgm': [
          {'startLine': 0, 'endLine': 4, 'materialId': 108, 'volume': 0.3},
        ],
        fieldName: [
          {'materialId': 108, 'name': '快乐的尤克里里', 'durationMs': 122540},
        ],
      };

  test('手册教的 offered 要认', () {
    expect(offeredBgmIds(bgmPayload('offered')), contains(108),
        reason: '手册配乐那节从头到尾只提 offered，照做的人一定撞这堵墙');
  });

  test('代码原本认的 candidates 继续认', () {
    expect(offeredBgmIds(bgmPayload('candidates')), contains(108),
        reason: '已经照着 shots 那节写对的人不能一夜之间失效');
  });

  test('挑镜头那条路同样两个名字都认', () {
    final payload = {
      'picks': [
        {'lineIndex': 0, 'materialIds': [105378]},
      ],
      'offered': [
        {'materialId': 105378, 'name': '素材', 'durationMs': 9000},
      ],
    };
    expect(offeredShotIds(payload), contains(105378));
  });

  test('一条候选都没给：这和「id 不在清单里」不是一回事', () {
    expect(offeredBgmIds({'bgm': []}), isEmpty);
  });
}
