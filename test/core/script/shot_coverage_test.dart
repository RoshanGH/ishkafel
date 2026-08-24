import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/shot_coverage.dart';

void main() {
  ScriptDoc docWith(List<LineShot> shots) => ScriptDoc([
        ScriptLine.create(text: '现在我们家每个月都有定期清理冰箱的好习惯')
            .withShots(shots),
      ]);

  group('画面够不够铺满坑位（按素材真实长度算）', () {
    test('素材够长：没话说', () {
      final gaps = shotCoverageGaps(docWith(const [
        LineShot(materialId: 1, name: 'a', durationMs: 16000, allocMs: 6048),
      ]));
      expect(gaps, isEmpty);
    });

    test('素材只有 1.2 秒却要铺 6 秒：点名，并说清差多少', () {
      // 真机踩到的那一镜：探测时长失败 → 当成无限长 → 分了 6 秒。
      // 成片里靠克隆最后一帧补满 4.8 秒（画面定格），预览里时间轴缩水
      final gaps = shotCoverageGaps(docWith(const [
        LineShot(materialId: 106720, name: '滴露冰箱', durationMs: 1207, allocMs: 6048),
      ]));
      expect(gaps, hasLength(1));
      expect(gaps.single.lineIndex, 0);
      expect(gaps.single.shotIndex, 0);
      expect(gaps.single.gapMs, 6048 - 1207);
      expect(gaps.single.name, '滴露冰箱');
    });

    test('从中间取段：可用量要扣掉取段起点', () {
      final gaps = shotCoverageGaps(docWith(const [
        LineShot(
            materialId: 1,
            name: 'a',
            durationMs: 5000,
            trimStartMs: 3000,
            allocMs: 4000),
      ]));
      expect(gaps.single.gapMs, 4000 - 2000);
    });

    test('放慢了就更不够，加快了就更够——按倍速折算', () {
      final slow = shotCoverageGaps(docWith(const [
        LineShot(materialId: 1, name: 'a', durationMs: 4000, speed: 0.5, allocMs: 8000),
      ]));
      expect(slow, isEmpty, reason: '0.5 倍速下 4 秒素材能出 8 秒画面');
      final fast = shotCoverageGaps(docWith(const [
        LineShot(materialId: 1, name: 'a', durationMs: 4000, speed: 2.0, allocMs: 4000),
      ]));
      expect(fast.single.gapMs, 2000, reason: '2 倍速下 4 秒素材只能出 2 秒');
    });

    test('几十毫秒的零头不算——那是取整误差，不是窟窿', () {
      final gaps = shotCoverageGaps(docWith(const [
        LineShot(materialId: 1, name: 'a', durationMs: 5990, allocMs: 6048),
      ]));
      expect(gaps, isEmpty);
    });

    test('素材时长还不知道（没下载完）：先不下结论', () {
      final gaps = shotCoverageGaps(docWith(const [
        LineShot(materialId: 1, name: 'a', allocMs: 6048),
      ]));
      expect(gaps, isEmpty, reason: '量到真实时长之前不该报警，那是猜的');
    });

    test('参考片切出来的本地段：整段都能用', () {
      final gaps = shotCoverageGaps(docWith(const [
        LineShot(
            materialId: -1,
            name: '参考段',
            localSource: '/v/ref.mp4',
            durationMs: 3000,
            trimStartMs: 12000,
            allocMs: 3000),
      ]));
      expect(gaps, isEmpty, reason: '本地段的 durationMs 就是区间长，不用减 trim');
    });
  });
}
