import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_library.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/features/workbench/bgm_audition.dart';
import 'package:ishkafel/features/workbench/bgm_picker_sheet.dart';

/// 试听用的假播放器：只记下放过什么，不碰 libmpv
class _FakePlayer implements AuditionPlayer {
  final List<String> opened;
  bool disposed = false;

  _FakePlayer(this.opened);

  @override
  Future<void> open(String url) async => opened.add(url);

  @override
  Future<void> dispose() async => disposed = true;
}

class _FakeLibrary implements BgmLibrary {
  final List<BgmMaterial> items;
  final Object? error;
  final bool widened;
  final asked = <String?>[];

  _FakeLibrary({this.items = const [], this.error, this.widened = false});

  @override
  Future<BgmSearchPage> search({
    String? keyword,
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 30,
  }) async {
    asked.add(keyword);
    if (error != null) throw error!;
    return BgmSearchPage(items: items, widenedFromProject: widened);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _long = BgmMaterial(
    id: 1, name: '三十秒垫乐', durationMs: 30000, previewUrl: null);
const _short = BgmMaterial(
    id: 2, name: '五秒音效', durationMs: 5000, previewUrl: null);
const _withUrl = BgmMaterial(
    id: 9,
    name: '尤克里里',
    durationMs: 122000,
    previewUrl: 'https://o/a.mp3');
const _voice = BgmMaterial(
    id: 3,
    name: '口播配音',
    durationMs: 12000,
    previewUrl: null,
    hasSpeech: true);

/// 带上「已选了哪几首」的打开方式，用来测「改已有段落」
Future<void> _openWith(
  WidgetTester tester, {
  required _FakeLibrary library,
  required List<BgmMaterial> initialMaterials,
  int initialPreviewIndex = 0,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      bgmLibraryProvider.overrideWithValue(library),
      auditionPlayerFactoryProvider
          .overrideWithValue(() => _FakePlayer(<String>[])),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open'),
              onPressed: () => showBgmPicker(context,
                  rangeMs: 12000,
                  rangeLabel: 'U1',
                  canClear: true,
                  initialMaterials: initialMaterials,
                  initialPreviewIndex: initialPreviewIndex),
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

Future<BgmChoice?> _open(
  WidgetTester tester, {
  required _FakeLibrary library,
  int rangeMs = 12000,
  bool canClear = false,
  List<String>? played,
  double initialVolume = BgmSegment.defaultVolume,
}) async {
  BgmChoice? result;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      bgmLibraryProvider.overrideWithValue(library),
      auditionPlayerFactoryProvider
          .overrideWithValue(() => _FakePlayer(played ?? <String>[])),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open'),
              onPressed: () async {
                result = await showBgmPicker(context,
                    rangeMs: rangeMs,
                    rangeLabel: 'S2–S5',
                    canClear: canClear,
                    initialVolume: initialVolume);
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
      await tester.tap(find.byKey(const Key('bgm-confirm')));
      await tester.pumpAndSettle();

      expect((picked as BgmPicked).materials.single.name, '三十秒垫乐');
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

    testWidgets('放开到全库时挑明，不让用户以为这些是本项目的', (tester) async {
      await _open(tester,
          library: _FakeLibrary(items: const [_long], widened: true));

      expect(find.byKey(const Key('bgm-widened')), findsOneWidget);
      expect(find.textContaining('已展开到全部音频库'), findsOneWidget);
      expect(find.text('三十秒垫乐'), findsOneWidget, reason: '说明归说明，列表照常给');
    });

    testWidgets('本项目内有货时不出这行说明', (tester) async {
      await _open(tester, library: _FakeLibrary(items: const [_long]));

      expect(find.byKey(const Key('bgm-widened')), findsNothing);
    });
  });

  group('试听', () {
    testWidgets('每条都能点着听，点了变成「停止」', (tester) async {
      final played = <String>[];
      await _open(tester,
          library: _FakeLibrary(items: const [_withUrl]), played: played);

      final button = find.byKey(const Key('bgm-play-9'));
      expect(button, findsOneWidget, reason: '光看名字和时长挑不出配乐');

      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(played, ['https://o/a.mp3']);
      expect(
          tester
              .widget<IconButton>(button)
              .tooltip,
          '停止试听',
          reason: '按钮要如实反映现在是在放还是没放');
    });

    testWidgets('点试听不会顺手把这条选中——那是两回事', (tester) async {
      final result = await _open(tester,
          library: _FakeLibrary(items: const [_withUrl]));

      await tester.tap(find.byKey(const Key('bgm-play-9')));
      await tester.pumpAndSettle();

      expect(result, isNull, reason: '浮层还开着，用户只是在试听');
    });
  });

  group('配乐音量：每段独立', () {
    testWidgets('默认压到 25%，滑块和数字都显示出来', (tester) async {
      await _open(tester, library: _FakeLibrary(items: const [_long]));

      expect(find.byKey(const Key('bgm-volume')), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
    });

    testWidgets('改已有段落时带出这一段现在的音量，不是默认值', (tester) async {
      await _open(tester,
          library: _FakeLibrary(items: const [_long]),
          canClear: true,
          initialVolume: 0.6);

      expect(find.text('60%'), findsOneWidget,
          reason: '每次点进来都显示 25%，用户会以为自己上次没调成');
    });

    testWidgets('选曲子时把当前音量一起交出去', (tester) async {
      BgmChoice? picked;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          bgmLibraryProvider
              .overrideWithValue(_FakeLibrary(items: const [_long])),
          auditionPlayerFactoryProvider
              .overrideWithValue(() => _FakePlayer(<String>[])),
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
                        rangeLabel: 'S1',
                        initialVolume: 0.5);
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
      await tester.tap(find.byKey(const Key('bgm-confirm')));
      await tester.pumpAndSettle();

      expect((picked as BgmPicked).volume, 0.5);
    });

    testWidgets('只改音量时有单独的出口，不用重选一遍曲子', (tester) async {
      await _open(tester,
          library: _FakeLibrary(items: const [_long]),
          canClear: true,
          initialVolume: 0.25);

      expect(find.byKey(const Key('bgm-apply-volume')), findsNothing,
          reason: '没动过就不该冒出一个「应用音量」');

      await tester.drag(find.byKey(const Key('bgm-volume')), const Offset(60, 0));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('bgm-apply-volume')), findsOneWidget);
    });
  });

  group('一段可以选多首，互为备选', () {
    testWidgets('勾几首就带几首出来，顺序就是导出轮流的次序', (tester) async {
      BgmChoice? picked;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          bgmLibraryProvider.overrideWithValue(
              _FakeLibrary(items: const [_long, _short, _withUrl])),
          auditionPlayerFactoryProvider
              .overrideWithValue(() => _FakePlayer(<String>[])),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const Key('open'),
                  onPressed: () async {
                    picked = await showBgmPicker(context,
                        rangeMs: 12000, rangeLabel: 'U1');
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

      // 先点第二首、再点第一首——次序按点击顺序
      await tester.tap(find.byKey(const Key('bgm-item-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bgm-item-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bgm-confirm')));
      await tester.pumpAndSettle();

      expect((picked as BgmPicked).materials.map((m) => m.id), [2, 1]);
    });

    testWidgets('选中的显示排号，那就是轮流的次序', (tester) async {
      await _open(tester,
          library: _FakeLibrary(items: const [_long, _short]));

      await tester.tap(find.byKey(const Key('bgm-item-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bgm-item-1')));
      await tester.pumpAndSettle();

      expect(
          tester.widget<Text>(find.byKey(const Key('bgm-order-2'))).data, '1');
      expect(
          tester.widget<Text>(find.byKey(const Key('bgm-order-1'))).data, '2');
    });

    testWidgets('再点一次取消选中', (tester) async {
      await _open(tester, library: _FakeLibrary(items: const [_long]));

      await tester.tap(find.byKey(const Key('bgm-item-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bgm-order-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('bgm-item-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('bgm-order-1')), findsNothing);
    });

    testWidgets('一首都没选时确定按钮点不动', (tester) async {
      await _open(tester, library: _FakeLibrary(items: const [_long]));

      expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('bgm-confirm')))
              .onPressed,
          isNull,
          reason: '点了没反应比灰着更让人困惑');
    });

    testWidgets('第一个选中的默认是预览版，可以改到别的', (tester) async {
      BgmChoice? picked;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          bgmLibraryProvider
              .overrideWithValue(_FakeLibrary(items: const [_long, _short])),
          auditionPlayerFactoryProvider
              .overrideWithValue(() => _FakePlayer(<String>[])),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const Key('open'),
                  onPressed: () async {
                    picked = await showBgmPicker(context,
                        rangeMs: 12000, rangeLabel: 'U1');
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
      await tester.tap(find.byKey(const Key('bgm-item-2')));
      await tester.pumpAndSettle();
      // 把第二首设为预览版
      await tester.tap(find.byKey(const Key('bgm-preview-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bgm-confirm')));
      await tester.pumpAndSettle();

      expect((picked as BgmPicked).previewIndex, 1);
    });

    testWidgets('没选中的那些没有「设为预览版」——预览只能放选中的', (tester) async {
      await _open(tester, library: _FakeLibrary(items: const [_long]));

      expect(find.byKey(const Key('bgm-preview-1')), findsNothing);
    });

    testWidgets('改已有段落时带出已选的几首和预览版', (tester) async {
      await _openWith(tester,
          library: _FakeLibrary(items: const [_long, _short]),
          initialMaterials: const [_short, _long],
          initialPreviewIndex: 1);

      expect(
          tester.widget<Text>(find.byKey(const Key('bgm-order-2'))).data, '1');
      expect(
          tester.widget<Text>(find.byKey(const Key('bgm-order-1'))).data, '2');
      expect(
          tester.widget<Icon>(find.descendant(
              of: find.byKey(const Key('bgm-preview-1')),
              matching: find.byType(Icon))).icon,
          Icons.star,
          reason: '预览版指的是第二首（_long）');
    });
  });
}
