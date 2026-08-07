import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

Future<void> _open(
  WidgetTester tester, {
  required List<UnitReplacement> replacements,
  ExportRunnerFactory? factory,
  bool withFactory = true,
}) async {
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
}
