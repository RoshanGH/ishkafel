import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';
import 'package:ishkafel/features/shared/subtitle_style_sheet.dart';

/// **调字幕样式要边调边看。**
///
/// 2026-09-09 真机，用户原话：「现在能调整了，但是没法实时显示位置，
/// 有点在盲调的感觉。」
///
/// 面板原来只在点「就这样」时才把样式交出去，于是人只能凭那两个数字
/// （「距底 21%」「23‰」）猜，点完才看得见结果，不对再开一次。而这套参数
/// 的用途本来就是**照着画面判断**——素材自带烧录字幕时要挑一个盖得住的
/// 遮罩，位置和字号更是纯看效果。
void main() {
  /// 弹窗的返回值放在外面这个变量里。
  ///
  /// **不能让 open 自己返回它**：`async` 函数返回一个 Future 会被展开，
  /// `await open(...)` 就变成「等这个弹窗关掉」——弹窗还开着，测试就挂死在
  /// 那儿（第一版就是这么写的，跑了七分钟没动静）。
  late Future<(SubtitleStyle, bool)?> result;

  Future<void> open(
    WidgetTester tester,
    List<SubtitleStyle> previews,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () {
              result = showSubtitleStyleSheet(context,
                  initial: SubtitleStyle.standard, onPreview: previews.add);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 滑杆直接调它的回调：模拟真实拖动要走一串手势帧，在测试里既慢又脆，
  /// 而这里要钉的是「动一下有没有推出去」，不是 Slider 本身
  Future<void> slide(WidgetTester tester, String key, double value) async {
    tester.widget<Slider>(find.byKey(ValueKey(key))).onChanged!(value);
    await tester.pump();
  }

  testWidgets('拖位置：每动一下都推出去，不是等点确定', (tester) async {
    final previews = <SubtitleStyle>[];
    await open(tester, previews);

    await slide(tester, 'subtitle-bottom', 0.30);

    expect(previews, isNotEmpty,
        reason: '不推的话人只能凭「距底 21%」这个数字盲调');
    expect(previews.last.bottomRatio, 0.30);
  });

  testWidgets('连着拖几格，每一格都推——所以调用方得自己节流', (tester) async {
    final previews = <SubtitleStyle>[];
    await open(tester, previews);

    for (final v in [0.10, 0.15, 0.20, 0.25]) {
      await slide(tester, 'subtitle-bottom', v);
    }

    expect(previews.map((s) => s.bottomRatio), [0.10, 0.15, 0.20, 0.25]);
  });

  testWidgets('字号同样边拖边推', (tester) async {
    final previews = <SubtitleStyle>[];
    await open(tester, previews);

    await slide(tester, 'subtitle-font', 0.05);

    expect(previews.last.fontRatio, 0.05);
  });

  testWidgets('换颜色、换遮罩也要立刻看得到', (tester) async {
    final previews = <SubtitleStyle>[];
    await open(tester, previews);

    await tester.tap(find.byKey(const ValueKey('subtitle-color-FFD900')));
    await tester.pump();
    expect(previews.last.colorHex, 'FFD900');

    await tester.tap(find.byKey(const ValueKey('subtitle-mask-blurBox')));
    await tester.pump();
    expect(previews.last.preset, SubtitlePreset.blurBox,
        reason: '遮罩是用来盖住素材自带字幕的，盖没盖住只能看画面');
  });

  testWidgets('点「就这样」返回的就是最后推出去的那一套', (tester) async {
    final previews = <SubtitleStyle>[];
    await open(tester, previews);

    await slide(tester, 'subtitle-bottom', 0.33);
    await tester.tap(find.byKey(const ValueKey('subtitle-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // SubtitleStyle 没有值相等，比它的指纹——渲染缓存也是按这个判命中的
    expect((await result)!.$1.fingerprint, previews.last.fingerprint,
        reason: '预览里看到的和最终落下的必须是同一套');
  });

  testWidgets('取消不返回任何东西——调用方据此把预览退回原样', (tester) async {
    final previews = <SubtitleStyle>[];
    await open(tester, previews);

    await slide(tester, 'subtitle-bottom', 0.40);
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(await result, isNull);
    expect(previews, isNotEmpty,
        reason: '推过预览，所以调用方必须把它退回去——'
            '人点了取消就是不要，不能留在半路上');
  });
}
