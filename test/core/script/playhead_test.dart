import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/playhead.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 播放头落在**哪一行的哪一镜**。
///
/// 用来做「播放到哪就把那一镜的操作栏展开」：人看着片子播过去，
/// 手边就是那一镜的取段、速度、原声——不用先找到那一行再点开。
void main() {
  ScriptDoc docWith(List<List<int>> allocsPerLine) => ScriptDoc([
        for (final allocs in allocsPerLine)
          ScriptLine.create(text: '句').withShots([
            for (var i = 0; i < allocs.length; i++)
              LineShot(
                  materialId: i + 1,
                  name: 'm$i',
                  durationMs: 99999,
                  allocMs: allocs[i]),
          ]),
      ]);

  test('落在第一行第一镜', () {
    final doc = docWith([
      [1000, 2000],
      [3000],
    ]);
    expect(shotAt(doc, const {0: 0, 1: 3000}, 500), (0, 0));
  });

  test('走过第一镜就是第二镜', () {
    final doc = docWith([
      [1000, 2000],
      [3000],
    ]);
    expect(shotAt(doc, const {0: 0, 1: 3000}, 1500), (0, 1));
  });

  test('边界归后一镜——1000ms 那一刻第二镜已经开始了', () {
    final doc = docWith([
      [1000, 2000],
    ]);
    expect(shotAt(doc, const {0: 0}, 1000), (0, 1));
  });

  test('跨到下一行', () {
    final doc = docWith([
      [1000, 2000],
      [3000],
    ]);
    expect(shotAt(doc, const {0: 0, 1: 3000}, 3500), (1, 0));
  });

  test('超过片尾：停在最后一镜，不返回 null——播完那一刻不该把面板收起来', () {
    final doc = docWith([
      [1000],
    ]);
    expect(shotAt(doc, const {0: 0}, 99999), (0, 0));
  });

  test('没进预览的行不算——它在轨道上根本没有位置', () {
    final doc = docWith([
      [1000],
      [2000],
    ]);
    // 第 0 行被跳过（lineStarts 里没有它）
    expect(shotAt(doc, const {1: 0}, 500), (1, 0));
  });

  test('没有镜头的行：给出行、镜为 null', () {
    final doc = ScriptDoc([ScriptLine.create(text: '句')]);
    expect(shotAt(doc, const {0: 0}, 100), (0, null));
  });

  test('一条都没铺时返回 null', () {
    expect(shotAt(ScriptDoc.empty(), const {}, 100), isNull);
  });

  test('时长还没算出来的镜跳过，不把播放头卡在它上面', () {
    final doc = ScriptDoc([
      ScriptLine.create(text: '句').withShots(const [
        LineShot(materialId: 1, name: 'a', durationMs: 9000),
        LineShot(materialId: 2, name: 'b', durationMs: 9000, allocMs: 2000),
      ]),
    ]);
    expect(shotAt(doc, const {0: 0}, 500), (0, 1));
  });
}
