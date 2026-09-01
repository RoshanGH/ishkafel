import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/shot_allocation.dart';

/// **自动铺一版的时长是「跟原分镜对齐」的**——参考里那一镜占这一行的
/// 几分之几，铺出来就占几分之几。
///
/// 产品负责人的原话：「第三行里面有 9 个分镜，你就要找 9 个，然后自动去切
/// 对应的时间，这是自动铺一版，这是机械化的程序。」均分会把 0.5 秒的快切和
/// 3 秒的定格拉成一样长，参考片的节奏就没了。
void main() {
  LineShot shot(int materialId, {int? durationMs}) => LineShot(
        materialId: materialId,
        name: 'm$materialId',
        voiceover: '',
        sceneDescription: '',
        durationMs: durationMs ?? 60000,
      );

  test('按参考各镜的比例分，不是均分', () {
    final out = ShotAllocation.distributeByReference(
      [shot(1), shot(2), shot(3)],
      // 行时长 6 秒
      6000,
      // 参考里三镜是 1:2:3
      const [(0, 1000), (1000, 3000), (3000, 6000)],
    );
    expect(out.map((s) => s.allocMs), [1000, 2000, 3000]);
  });

  test('总和锁死等于行时长——一毫秒都不能多也不能少', () {
    final out = ShotAllocation.distributeByReference(
      [shot(1), shot(2), shot(3)],
      5000,
      const [(0, 700), (700, 2100), (2100, 3300)],
    );
    expect(out.fold<int>(0, (a, s) => a + (s.allocMs ?? 0)), 5000,
        reason: '行内所有 allocMs 之和 = 行时长，除不尽的余数也要分掉');
  });

  test('参考镜短得离谱时也不低于最短镜长', () {
    final out = ShotAllocation.distributeByReference(
      [shot(1), shot(2)],
      6000,
      // 第一镜只有 30ms
      const [(0, 30), (30, 6000)],
    );
    expect(out.first.allocMs, greaterThanOrEqualTo(ShotAllocation.minShotMs));
    expect(out.fold<int>(0, (a, s) => a + (s.allocMs ?? 0)), 6000);
  });

  test('素材不够长时先分到可用量为止，缺口留给放慢去补', () {
    final out = ShotAllocation.distributeByReference(
      [shot(1, durationMs: 800), shot(2)],
      6000,
      const [(0, 3000), (3000, 6000)],
    );
    expect(out.first.allocMs, lessThanOrEqualTo(out.first.availableMs),
        reason: '分得比素材还长是假的，那段画面根本不存在');
  });

  test('镜头数和参考镜数对不上时按均分退回——不假装对得上', () {
    final out = ShotAllocation.distributeByReference(
      [shot(1), shot(2)],
      6000,
      const [(0, 1000), (1000, 3000), (3000, 6000)],
    );
    expect(out.map((s) => s.allocMs), [3000, 3000]);
  });

  test('没有参考镜就均分', () {
    final out =
        ShotAllocation.distributeByReference([shot(1), shot(2)], 4000, const []);
    expect(out.map((s) => s.allocMs), [2000, 2000]);
  });
}
