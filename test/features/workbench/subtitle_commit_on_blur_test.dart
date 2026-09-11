import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/features/workbench/subtitle_editor_card.dart';

/// **改字幕时每敲一个字都不该触发重烧。**
///
/// 2026-09-08 真机，用户原话：「我在属性里面去改字幕的时候，我每键入一下，
/// 它都会提示那个正在烧录。这个东西我觉得可以在我修改完光标离开的时候，
/// 你再去进行烧录会好一点。」
///
/// 一句字幕十来个字就是十来次重烧，每次都要跑一遍 ffmpeg——机器忙、横幅一直
/// 在闪，而中间那十几个半截状态没有任何意义（「李」「李斯」「李斯特」…）。
///
/// 改成**离开这一格才提交**：光标还在框里就只是本地编辑。
void main() {
  late List<SubtitleLine> current;
  late int commits;

  Future<void> pump(WidgetTester tester) async {
    current = const [
      SubtitleLine(startMs: 0, endMs: 800, text: '了李斯特菌'),
      SubtitleLine(startMs: 800, endMs: 1600, text: '沙门氏菌的游乐场'),
    ];
    commits = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SubtitleEditorCard(
            slotDurationMs: 60000,
            replaced: true,
            lines: current,
            edited: true,
            onChanged: (v) => setState(() {
              current = v;
              commits++;
            }),
            onResetToAuto: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('敲字的过程中一次都不提交', (tester) async {
    await pump(tester);

    for (final v in const ['李', '李斯', '李斯特', '李斯特菌']) {
      await tester.enterText(
          find.byKey(const ValueKey('subtitle-text-0')), v);
      await tester.pump();
    }

    expect(commits, 0,
        reason: '每敲一下提交一次 = 每敲一下重烧一次，'
            '横幅一直在闪，中间那些半截状态毫无意义');
  });

  testWidgets('光标离开这一格时提交一次，内容是最后敲完的那个', (tester) async {
    await pump(tester);

    await tester.enterText(
        find.byKey(const ValueKey('subtitle-text-0')), '李斯特菌');
    await tester.pump();
    // 点到第二格 = 离开第一格
    await tester.tap(find.byKey(const ValueKey('subtitle-text-1')));
    await tester.pumpAndSettle();

    expect(commits, 1);
    expect(current.first.text, '李斯特菌');
  });

  testWidgets('没改就离开，不提交——不该白烧一次', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('subtitle-text-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('subtitle-text-1')));
    await tester.pumpAndSettle();

    expect(commits, 0);
  });

  testWidgets('删一整段仍然是立刻生效——那不是敲字', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('subtitle-remove-0')));
    await tester.pumpAndSettle();

    expect(commits, 1);
    expect(current.length, 1);
  });

  testWidgets('加一段也是立刻生效', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('subtitle-add')));
    await tester.pumpAndSettle();

    expect(commits, 1);
    expect(current.length, 3);
  });
}
