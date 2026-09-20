import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/time/rational.dart';
import 'package:ishkafel/core/timeline/composed_frames.dart';

/// **全软件唯一的排序基准：成片帧轴。**
///
/// 为什么是成片不是原片：手动添加的单元在原片轴上根本没有位置
/// （`hasSource=false`），拿原片轴当基准它们只能排在末尾或者编个假坐标——
/// 而人恰恰是把它们插在中间的。
///
/// 为什么是帧不是毫秒：「这个字属于哪一镜」是边界问题。毫秒上相邻两段
/// 共享边界（前一段的 endMs == 后一段的 startMs），回答不了；帧上是闭区间，
/// 相邻段不共享任何一帧，落在哪个区间里就是哪一镜的。
void main() {
  List<SemanticUnit> units() => const [
        SemanticUnit(
          uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '甲',
          shots: [
            Shot(startMs: 0, endMs: 1000),
            Shot(startMs: 1000, endMs: 2000),
          ],
        ),
        SemanticUnit(
          uid: 'u1', index: 1, startMs: 2000, endMs: 5000, transcript: '乙',
          shots: [Shot(startMs: 2000, endMs: 5000)],
        ),
      ];

  ComposedFrames framesOf({Map<int, int> whole = const {}, Rational? fps}) =>
      ComposedFrames.of(
        timeline: ComposedTimeline.of(units: units(), wholeDurations: whole),
        fps: fps,
      );

  test('相邻两镜不共享任何一帧', () {
    final f = framesOf(fps: Rational.fps30);
    final s1 = f.shotSpan(0, 0)!;
    final s2 = f.shotSpan(0, 1)!;
    expect(s2.first, s1.last + 1,
        reason: '毫秒上 1000 同时属于两镜，帧上必须只属于后一镜——'
            '「这个字属于哪一镜」全靠这条才回答得了');
  });

  test('整体替换改了时长，后面的单元跟着挪', () {
    final f = framesOf(whole: {0: 5000}, fps: Rational.fps30);
    expect(f.unitSpan(1).first, f.frameAt(5000),
        reason: 'U1 被换成 5 秒的素材，U2 在成片里就从第 5000 毫秒开始');
  });

  test('整块段落没有镜头可定位，返回 null 而不是编一个', () {
    final f = framesOf(whole: {0: 5000}, fps: Rational.fps30);
    expect(f.shotSpan(0, 0), isNull);
  });

  test('时间码带帧号，精确到帧', () {
    final f = framesOf(fps: Rational.fps30);
    expect(f.tc(0), '00:00:00:00');
    expect(f.tc(30), '00:00:01:00');
    expect(f.tc(612), '00:00:20:12');
  });

  test('拿不到原片帧率就退到 30，**并且说出来**', () {
    final f = framesOf();
    expect(f.fps, Rational.fps30);
    expect(f.fpsSource, 'default',
        reason: '退化值和真值长得一模一样，不说就是静默降级');
  });

  test('拿得到就标 original', () {
    expect(framesOf(fps: Rational.fps30).fpsSource, 'original');
  });

  test('29.97 下帧号不许溢出——每一秒的最后一帧最容易犯', () {
    final f = ComposedFrames.of(
      timeline: ComposedTimeline.of(units: units(), wholeDurations: const {}),
      fps: Rational(30000, 1001),
    );
    for (final frame in [30, 1798, 2997, 5000]) {
      final ff = int.parse(f.tc(frame).split(':').last);
      expect(ff, lessThan(30),
          reason: '帧号字段必须落在 [0, 标称帧率) 内，'
              'tc($frame) 给的是 ${f.tc(frame)}');
    }
  });

  test('边界不落在帧点上时，相邻两段也不许共享帧', () {
    // 5237ms 是整体替换给出的素材真实时长——它直接来自 ffprobe，
    // 根本不过帧对齐那一步，所以这是生产里必然出现的输入，不是边角
    final f = framesOf(whole: {0: 5237}, fps: Rational.fps30);
    // **断言必须是「正好接上」，不是「大于」。** greaterThan 只挡得住
    // 「共享同一帧」，挡不住「中间凭空空掉几帧」——而这是整条分支里唯一
    // 守「相邻段不共享帧」的边界用例，松一档就等于没守。
    // 5237ms 这组实际是 157/158，正好接上
    expect(f.unitSpan(1).first, f.unitSpan(0).last + 1,
        reason: '帧 157 的时间戳是 5233ms，早于边界 5237ms——'
            '四舍五入会把它同时判给两段；而跳着走又会让中间那几帧无主');
  });
}
