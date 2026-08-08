import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/export_record.dart';
import 'package:ishkafel/core/export/export_runner.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/export/export_dialog.dart';

/// 假 ffmpeg：不起进程，按需失败
class _Ffmpeg {
  final String? failOn;
  _Ffmpeg({this.failOn});

  Future<ProcessResult> call(String bin, List<String> args) async {
    if (failOn != null && args.join(' ').contains(failOn!)) {
      return ProcessResult(1, 1, '', '素材读不出来');
    }
    File(args.last).writeAsStringSync('x');
    return ProcessResult(1, 0, '', '');
  }
}

List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: 'U1',
        shots: [Shot(startMs: 0, endMs: 2000)],
      ),
      SemanticUnit(
        index: 1,
        startMs: 2000,
        endMs: 5000,
        transcript: 'U2',
        shots: [Shot(startMs: 2000, endMs: 5000)],
      ),
    ];

/// 这一轮里对话框往外报了什么
final _recorded = <ExportRecord>[];
final _revealed = <String>[];

Future<void> _open(
  WidgetTester tester, {
  required List<UnitReplacement> replacements,
  ExportRunnerFactory? factory,
  bool withFactory = true,
  String? pickedDir,
  Future<void> Function(String)? reveal,
  List<ExportRecord> exports = const [],
}) async {
  _recorded.clear();
  _revealed.clear();
  final work = Directory.systemTemp.createTempSync('ishkafel_ed_work_');
  final out = Directory.systemTemp.createTempSync('ishkafel_ed_out_');
  addTearDown(() {
    // 导出跑完会自己把工作目录清掉
    if (work.existsSync()) work.deleteSync(recursive: true);
    out.deleteSync(recursive: true);
  });

  final resolved = factory ??
      (String taskId) => ExportRunner(
            run: _Ffmpeg().call,
            workDir: work,
            fetchMaterial: (id) async {
              final f = File('${work.path}/m$id.mp4')..writeAsStringSync('m');
              return f.path;
            },
          );

  await tester.pumpWidget(ProviderScope(
    overrides: [
      exportRunnerFactoryProvider
          .overrideWithValue(withFactory ? resolved : null),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open'),
              onPressed: () => showExportDialog(
                context,
                taskId: 't1',
                taskName: '滴露',
                sourcePath: '/v/a.mp4',
                units: _units(),
                replacements: replacements,
                outputDir: out,
                pickDirectory: () async => pickedDir,
                revealDirectory: reveal ?? (path) async => _revealed.add(path),
                onExported: (r) async => _recorded.add(r),
                now: () => DateTime.utc(2026, 8, 9, 10, 30),
                exports: exports,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('先说清要导出几条、每条多长、导到哪儿', (tester) async {
    await _open(tester, replacements: [
      UnitReplacement.whole(const [11, 12]),
      UnitReplacement.keepOriginal(),
    ]);

    expect(find.textContaining('共 2 条成片'), findsOneWidget);
    expect(find.textContaining('5.0s'), findsOneWidget);
    expect(find.textContaining('导出到：'), findsOneWidget);
  });

  testWidgets('跟原片一样的那几条要点出来——用户按条数付出的是等待时间',
      (tester) async {
    await _open(tester, replacements: [
      UnitReplacement.keepOriginal(),
      UnitReplacement.keepOriginal(),
    ]);

    expect(find.textContaining('1 条与原片画面相同'), findsOneWidget);
  });

  testWidgets('导出跑完给出结果', (tester) async {
    await _open(tester, replacements: [
      UnitReplacement.whole(const [11, 12]),
      UnitReplacement.keepOriginal(),
    ]);

    await tester.tap(find.byKey(const Key('export-start')));
    await tester.pumpAndSettle();

    expect(find.text('2 条全部导出完成'), findsOneWidget);
    expect(find.byKey(const Key('export-start')), findsNothing,
        reason: '跑完了就没有「再开始一次」这回事，避免重复导出');
  });

  testWidgets('失败的逐条点名带原因，不让用户自己找', (tester) async {
    final work = Directory.systemTemp.createTempSync('ishkafel_ed_fail_');
    addTearDown(() {
      if (work.existsSync()) work.deleteSync(recursive: true);
    });

    await _open(
      tester,
      replacements: [
        UnitReplacement.whole(const [11, 12]),
        UnitReplacement.keepOriginal(),
      ],
      factory: (taskId) => ExportRunner(
        run: _Ffmpeg(failOn: 'm12.mp4').call,
        workDir: work,
        fetchMaterial: (id) async {
          final f = File('${work.path}/m$id.mp4')..writeAsStringSync('m');
          return f.path;
        },
      ),
    );

    await tester.tap(find.byKey(const Key('export-start')));
    await tester.pumpAndSettle();

    expect(find.textContaining('成功 1 条，失败 1 条'), findsOneWidget);
    expect(find.textContaining('第 2 条：'), findsOneWidget);
    expect(find.textContaining('素材读不出来'), findsOneWidget);
  });

  testWidgets('没有 ffmpeg 时说清楚，而不是点了没反应', (tester) async {
    await _open(
      tester,
      replacements: [UnitReplacement.keepOriginal()],
      withFactory: false,
    );

    await tester.tap(find.byKey(const Key('export-start')));
    await tester.pumpAndSettle();

    expect(find.textContaining('未检测到 ffmpeg'), findsOneWidget);
  });

  group('导完要知道片子在哪', () {
    /// 用户原话：「导出以后能让我直接知道在哪个地方，能让我看到它。现在导出
    /// 以后我点关闭，我就不知道在哪了。」
    testWidgets('开始之前能换导出位置', (tester) async {
      final elsewhere =
          Directory.systemTemp.createTempSync('ishkafel_ed_pick_');
      addTearDown(() => elsewhere.deleteSync(recursive: true));

      await _open(tester,
          replacements: [UnitReplacement.whole(const [11])],
          pickedDir: elsewhere.path);

      await tester.tap(find.byKey(const Key('export-pick-dir')));
      await tester.pumpAndSettle();

      expect(find.textContaining(elsewhere.path), findsOneWidget);
    });

    testWidgets('选择框里取消就保持原样，不要把已填好的位置清掉', (tester) async {
      await _open(tester,
          replacements: [UnitReplacement.whole(const [11])],
          pickedDir: null);
      final before = tester
          .widget<Text>(find.byKey(const Key('export-output-dir')))
          .data;

      await tester.tap(find.byKey(const Key('export-pick-dir')));
      await tester.pumpAndSettle();

      expect(
          tester
              .widget<Text>(find.byKey(const Key('export-output-dir')))
              .data,
          before);
    });

    testWidgets('跑完给「在访达中显示」，点了就打开那个目录', (tester) async {
      await _open(tester, replacements: [UnitReplacement.whole(const [11])]);
      expect(find.byKey(const Key('export-reveal')), findsNothing,
          reason: '还没导就摆一个「打开目录」是空指望');

      await tester.tap(find.byKey(const Key('export-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-reveal')));
      await tester.pumpAndSettle();

      expect(_revealed, hasLength(1));
    });

    testWidgets('打不开时说清楚，而不是点了没反应', (tester) async {
      await _open(tester,
          replacements: [UnitReplacement.whole(const [11])],
          reveal: (_) async => throw StateError('没这个目录'));

      await tester.tap(find.byKey(const Key('export-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-reveal')));
      await tester.pumpAndSettle();

      expect(find.textContaining('打不开这个目录'), findsOneWidget);
    });
  });

  group('每一次导出都记进项目', () {
    /// 项目没有终态——原片放在那儿，明天换一批素材还能再导。有始有终的是
    /// 每一次导出：哪天、导了几条、成了几条、在哪个目录。
    testWidgets('跑完就报一条记录', (tester) async {
      await _open(tester, replacements: [
        UnitReplacement.whole(const [11, 12]),
        UnitReplacement.keepOriginal(),
      ]);

      await tester.tap(find.byKey(const Key('export-start')));
      await tester.pumpAndSettle();

      expect(_recorded, hasLength(1));
      expect(_recorded.single.at, DateTime.utc(2026, 8, 9, 10, 30));
      expect(_recorded.single.total, 2);
      expect(_recorded.single.succeeded, 2);
      expect(_recorded.single.outputDir, isNotEmpty);
    });

    testWidgets('有失败的照样记，成功数如实报', (tester) async {
      final work = Directory.systemTemp.createTempSync('ishkafel_ed_rec_');
      addTearDown(() {
        if (work.existsSync()) work.deleteSync(recursive: true);
      });
      await _open(
        tester,
        replacements: [
          UnitReplacement.whole(const [11, 12]),
          UnitReplacement.keepOriginal(),
        ],
        factory: (taskId) => ExportRunner(
          run: (binary, args) async {
            // 第二条的素材取不到
            await File(args.last).writeAsString('out');
            return ProcessResult(1, 0, '', '');
          },
          workDir: work,
          fetchMaterial: (id) async {
            if (id == 12) throw StateError('素材读不出来');
            final f = File('${work.path}/m$id.mp4')..writeAsStringSync('m');
            return f.path;
          },
        ),
      );

      await tester.tap(find.byKey(const Key('export-start')));
      await tester.pumpAndSettle();

      expect(_recorded, hasLength(1));
      expect(_recorded.single.succeeded, lessThan(_recorded.single.total));
      expect(_recorded.single.allSucceeded, isFalse);
    });
  });

  group('确认页上摆出这个项目的导出历史', () {
    /// 用户原话：「每一个项目点导出的时候，它不是最后还要确认一下吗？
    /// 你可以在那个页面里展示出这个项目之前导出的这个历史。」——正要导之前
    /// 先看一眼上次导到哪儿、导了几条，比另开一个界面顺手。
    ExportRecord rec(int day, int succeeded, int total, String dir) =>
        ExportRecord(
            at: DateTime.utc(2026, 8, day, 20, 15),
            total: total,
            succeeded: succeeded,
            outputDir: dir);

    testWidgets('没导过就不摆这一段，不留一个空标题', (tester) async {
      await _open(tester, replacements: [UnitReplacement.whole(const [11])]);

      expect(find.byKey(const Key('export-history-title')), findsNothing);
    });

    testWidgets('导过就列出来：时间、几条、导到哪儿', (tester) async {
      await _open(
        tester,
        replacements: [UnitReplacement.whole(const [11])],
        exports: [rec(8, 6, 6, '/Users/me/Movies/滴露')],
      );

      expect(find.textContaining('导出过 1 次'), findsOneWidget);
      expect(find.textContaining('8月8日'), findsOneWidget);
      expect(find.textContaining('6 条'), findsOneWidget);
      expect(find.textContaining('Movies/滴露'), findsOneWidget);
    });

    testWidgets('有失败的那次要点出来', (tester) async {
      await _open(
        tester,
        replacements: [UnitReplacement.whole(const [11])],
        exports: [rec(8, 4, 6, '/out')],
      );

      expect(find.textContaining('2 条失败'), findsOneWidget);
    });

    testWidgets('最近的排在最前——用户找的多半是刚导的那批', (tester) async {
      await _open(
        tester,
        replacements: [UnitReplacement.whole(const [11])],
        exports: [rec(7, 1, 1, '/older'), rec(9, 2, 2, '/newer')],
      );

      final rows = tester
          .widgetList<Text>(find.textContaining('月'))
          .map((t) => t.data!)
          .where((d) => d.contains('日'))
          .toList();
      expect(rows.first, contains('9日'));
    });

    testWidgets('每一条都能直接打开——历史的用处就是回去找那批片子', (tester) async {
      final at = DateTime.utc(2026, 8, 8, 20, 15);
      await _open(
        tester,
        replacements: [UnitReplacement.whole(const [11])],
        exports: [rec(8, 6, 6, '/Users/me/Movies/滴露')],
      );

      await tester.tap(find
          .byKey(Key('export-history-open-${at.toIso8601String()}')));
      await tester.pumpAndSettle();

      expect(_revealed, ['/Users/me/Movies/滴露']);
    });

    testWidgets('导过很多次时只列最近五次，其余写个条数', (tester) async {
      await _open(
        tester,
        replacements: [UnitReplacement.whole(const [11])],
        exports: [for (var d = 1; d <= 8; d++) rec(d, 1, 1, '/out$d')],
      );

      expect(find.textContaining('导出过 8 次'), findsOneWidget);
      expect(find.textContaining('另有 3 次更早的导出'), findsOneWidget,
          reason: '全列出来会把确认页撑长，反而看不清这一次要导什么');
    });

    testWidgets('刚导完的这一次立刻出现在历史里', (tester) async {
      await _open(tester, replacements: [UnitReplacement.whole(const [11])]);
      expect(find.byKey(const Key('export-history-title')), findsNothing);

      await tester.tap(find.byKey(const Key('export-start')));
      await tester.pumpAndSettle();

      expect(find.textContaining('导出过 1 次'), findsOneWidget);
      expect(find.textContaining('8月9日'), findsOneWidget);
    });
  });

  group('路径写法', () {
    test('家目录缩成 ~——导出路径很长，全写出来会把那一行挤没', () {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return;

      expect(shortenPath('$home/Movies/滴露'), '~/Movies/滴露');
      expect(shortenPath('/Volumes/外置盘/片子'), '/Volumes/外置盘/片子',
          reason: '不在家目录下的原样显示');
    });
  });
}
