import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_library.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/features/workbench/bgm_audition.dart';
import 'package:ishkafel/features/workbench/bgm_picker_sheet.dart';

/// **能多选，就得让人看得出能多选。**
///
/// 2026-09-14 用户：「选择背景音乐的时候可以多选……现在只能选一个。」
/// 真机验下来多选一直是通的——问题全在界面：行首是空心圆（radio 的语言）、
/// 按钮写着「选一首」、「可以多选」那句话要选到第二首才出现。
/// 人是在选第二首**之前**需要知道这件事的。
class _FakePlayer implements AuditionPlayer {
  @override
  Future<void> open(String url) async {}
  @override
  Future<void> dispose() async {}
}

class _FakeLibrary implements BgmLibrary {
  final List<BgmMaterial> items;
  _FakeLibrary(this.items);

  @override
  Future<BgmSearchPage> search({
    String? keyword,
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 30,
  }) async =>
      BgmSearchPage(items: items, widenedFromProject: false);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _a = BgmMaterial(id: 1, name: '轻快垫乐', durationMs: 30000, previewUrl: null);
const _b = BgmMaterial(id: 2, name: '紧张的气氛', durationMs: 40000, previewUrl: null);

void main() {
  BgmChoice? picked;

  Future<void> open(WidgetTester tester, {bool singleSelect = false}) async {
    picked = null;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bgmLibraryProvider.overrideWithValue(_FakeLibrary(const [_a, _b])),
        auditionPlayerFactoryProvider.overrideWithValue(_FakePlayer.new),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('open'),
                onPressed: () async {
                  picked = await showBgmPicker(context,
                      rangeMs: 12000,
                      rangeLabel: 'U1–U2',
                      singleSelect: singleSelect);
                },
                child: const Text('开'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
  }

  String buttonLabel(WidgetTester tester) => tester
      .widget<Text>(find.descendant(
          of: find.byKey(const Key('bgm-confirm')), matching: find.byType(Text)))
      .data!;

  testWidgets('一首都没选时就说清可以多选——不能等选了第二首才说',
      (tester) async {
    await open(tester);

    final hint = tester
        .widget<Text>(find.descendant(
            of: find.byKey(const Key('bgm-multi-hint')),
            matching: find.byType(Text)))
        .data!;
    expect(hint, contains('好几首'));
    expect(hint, contains('轮流'), reason: '要说清多选出来的几首是怎么用的');
  });

  testWidgets('行首是方框不是圆点——空心圆是单选的语言', (tester) async {
    await open(tester);
    expect(find.byIcon(Icons.check_box_outline_blank), findsNWidgets(2));
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
  });

  testWidgets('按钮说「至少选一首」，不是「选一首」', (tester) async {
    await open(tester);
    expect(buttonLabel(tester), '至少选一首');
  });

  testWidgets('选两首：两首都留着，按钮报数，次序就是轮流用的次序',
      (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const Key('bgm-item-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bgm-item-2')));
    await tester.pumpAndSettle();

    // 点第二首不该把第一首顶掉
    expect(find.byKey(const Key('bgm-order-1')), findsOneWidget);
    expect(find.byKey(const Key('bgm-order-2')), findsOneWidget);
    expect(buttonLabel(tester), '用这 2 首');

    await tester.tap(find.byKey(const Key('bgm-confirm')));
    await tester.pumpAndSettle();
    final result = picked as BgmPicked;
    expect(result.materials.map((m) => m.id), [1, 2]);
    expect(result.previewIndex, 0, reason: '第一首默认当预览版');
  });

  testWidgets('编导台那条线还是单选：圆点、也不出那句多选提示',
      (tester) async {
    await open(tester, singleSelect: true);
    expect(find.byKey(const Key('bgm-multi-hint')), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
    expect(find.byIcon(Icons.check_box_outline_blank), findsNothing);

    await tester.tap(find.byKey(const Key('bgm-item-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bgm-item-2')));
    await tester.pumpAndSettle();
    expect(buttonLabel(tester), '用这一首', reason: '单选：换一首就是换掉');
  });
}
