import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ui/text_editing_keys.dart';

/// 2026-09-09 真机，用户原话：「我希望空格可以是暂停或者播放的快捷键，
/// 但是不要影响我打字输入中文。你改了打字输入中文之后，空格就不能正常
/// 暂停播放了。」
///
/// 两条都要成立，而它们打架：
/// - 焦点在输入框里：空格是打空格，输入法组合时是**选词上屏**，绝不能被
///   页面级快捷键抢走（抢走的表现就是「汉字打不进去」）；
/// - 焦点不在输入框里：空格是播放/暂停。
///
/// 判定走 [isEditableTextFocused]。漏的那一环是**怎么算「不在输入框里」**：
/// macOS 上点了别处 TextField 并不会自动失焦，人打完字去时间线上点一下，
/// 焦点还留在框里，空格就一直被放行、播放/暂停失灵。
void main() {
  testWidgets('焦点在输入框里：算「正在打字」，空格要留给输入法', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: TextField(key: Key('f'))),
    ));

    await tester.tap(find.byKey(const Key('f')));
    await tester.pumpAndSettle();

    expect(isEditableTextFocused(), isTrue);
  });

  testWidgets('点到别处之后就不算在打字了——空格该还给播放/暂停',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          TextField(
            key: const Key('f'),
            onTapOutside: releaseFocusOnTapOutside,
          ),
          const SizedBox(
              key: Key('outside'), width: 200, height: 200),
        ]),
      ),
    ));

    await tester.tap(find.byKey(const Key('f')));
    await tester.pumpAndSettle();
    expect(isEditableTextFocused(), isTrue);

    // 人打完字，去时间线上点一下
    await tester.tapAt(tester.getCenter(find.byKey(const Key('outside'))));
    await tester.pumpAndSettle();

    expect(isEditableTextFocused(), isFalse,
        reason: '焦点还留在框里的话，空格会一直被当成「在框里打空格」，'
            '播放/暂停就此失灵');
  });

  testWidgets('没有接 onTapOutside 的输入框，点别处焦点是不会走的',
      (tester) async {
    // 这条不是在测 Flutter，是把「为什么必须显式接这一手」钉下来：
    // 少接一个输入框，空格就在那一个上失灵
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [
          TextField(key: Key('f')),
          SizedBox(key: Key('outside'), width: 200, height: 200),
        ]),
      ),
    ));

    await tester.tap(find.byKey(const Key('f')));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byKey(const Key('outside'))));
    await tester.pumpAndSettle();

    expect(isEditableTextFocused(), isTrue);
  });
}
