import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_library.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/features/workbench/bgm_picker_sheet.dart';

class _FakeLibrary implements BgmLibrary {
  final List<BgmMaterial> items;
  final Object? error;
  final asked = <String?>[];

  _FakeLibrary({this.items = const [], this.error});

  @override
  Future<List<BgmMaterial>> search({
    String? keyword,
    int page = 1,
    int pageSize = 30,
  }) async {
    asked.add(keyword);
    if (error != null) throw error!;
    return items;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _long = BgmMaterial(
    id: 1, name: '三十秒垫乐', durationMs: 30000, previewUrl: null);
const _short = BgmMaterial(
    id: 2, name: '五秒音效', durationMs: 5000, previewUrl: null);
const _voice = BgmMaterial(
    id: 3,
    name: '口播配音',
    durationMs: 12000,
    previewUrl: null,
    hasSpeech: true);

Future<BgmChoice?> _open(
  WidgetTester tester, {
  required _FakeLibrary library,
  int rangeMs = 12000,
  bool canClear = false,
}) async {
  BgmChoice? result;
  await tester.pumpWidget(ProviderScope(
    overrides: [bgmLibraryProvider.overrideWithValue(library)],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open'),
              onPressed: () async {
                result = await showBgmPicker(context,
                    rangeMs: rangeMs, rangeLabel: 'S2–S5', canClear: canClear);
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
  return result;
}

void main() {
  group('列出音频库并说清每条怎么铺', () {
    testWidgets('进来就列全部，不必先搜', (tester) async {
      final library = _FakeLibrary(items: const [_long, _short]);
      await _open(tester, library: library);

      expect(find.text('三十秒垫乐'), findsOneWidget);
      expect(find.text('五秒音效'), findsOneWidget);
      expect(library.asked.single, anyOf(isNull, ''),
          reason: '一进来就让用户想关键词，等于把「先看看有什么」这条路堵死');
    });

    testWidgets('当场算出这条会裁还是会循环', (tester) async {
      await _open(tester,
          library: _FakeLibrary(items: const [_long, _short]), rangeMs: 12000);

      expect(find.text(BgmFit.cut.label), findsOneWidget);
      expect(find.text(BgmFit.loop.label), findsOneWidget);
    });

    testWidgets('含人声的标出来——压在成片下面会和原片口播打架', (tester) async {
      await _open(tester, library: _FakeLibrary(items: const [_voice, _long]));

      expect(find.byKey(const Key('bgm-speech-3')), findsOneWidget);
      expect(find.byKey(const Key('bgm-speech-1')), findsNothing);
    });

    testWidgets('时长未知的条目如实写，不显示 0.0s', (tester) async {
      await _open(
        tester,
        library: _FakeLibrary(items: const [
          BgmMaterial(id: 9, name: '缺时长', durationMs: 0, previewUrl: null)
        ]),
      );

      expect(find.text('时长未知'), findsOneWidget);
    });
  });

  group('选择结果', () {
    testWidgets('点一条就把它交出去', (tester) async {
      BgmChoice? picked;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          bgmLibraryProvider
              .overrideWithValue(_FakeLibrary(items: const [_long]))
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const Key('open'),
                  onPressed: () async {
                    picked = await showBgmPicker(context,
                        rangeMs: 12000, rangeLabel: 'S1');
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

      await tester.tap(find.byKey(const Key('bgm-item-1')));
      await tester.pumpAndSettle();

      expect((picked as BgmPicked).material.name, '三十秒垫乐');
    });

    testWidgets('已有配乐时才给「移除」，新建区间时不给', (tester) async {
      await _open(tester,
          library: _FakeLibrary(items: const [_long]), canClear: true);
      expect(find.byKey(const Key('bgm-clear')), findsOneWidget);

      await tester.tap(find.byKey(const Key('bgm-cancel')));
      await tester.pumpAndSettle();

      await _open(tester, library: _FakeLibrary(items: const [_long]));
      expect(find.byKey(const Key('bgm-clear')), findsNothing,
          reason: '这段本来就没有配乐，摆一个「移除」只会让人以为有');
    });
  });

  group('拿不到内容时说人话', () {
    testWidgets('检索失败给出可重试的中文提示，不摊原始异常', (tester) async {
      await _open(
        tester,
        library: _FakeLibrary(
            error: MiaoaException('素材库登录已失效，请在终端执行 miaoa auth login 后重试')),
      );

      expect(find.textContaining('miaoa auth login'), findsOneWidget);
      expect(find.byKey(const Key('bgm-retry')), findsOneWidget);
    });

    testWidgets('库里没有匹配内容时说清是空的，不留白', (tester) async {
      await _open(tester, library: _FakeLibrary(items: const []));

      expect(find.textContaining('没有匹配'), findsOneWidget);
    });
  });
}
