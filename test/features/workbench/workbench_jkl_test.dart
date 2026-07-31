import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';
import 'package:ishkafel/features/workbench/workbench_page.dart';
import 'package:ishkafel/features/workbench/workbench_shortcuts.dart';

class _Repo implements TaskRepository {
  final _store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async => _store.values.toList();
  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async => _store[task.id] = task;
  @override
  Future<void> delete(String id) async => _store.remove(id);
}

TimelineMediaBuilder _fakeMediaBuilder() => TimelineMediaBuilder(
      thumbnails: ThumbnailService(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(600, 1));
        return ProcessResult(1, 0, '', '');
      }),
      audio: AudioExtractor(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(64, 0));
        return ProcessResult(1, 0, '', '');
      }),
    );

RenewTask _task() => RenewTask(
      id: 't1',
      name: '测试成片',
      sourcePath: '/tmp/x.mp4',
      videoInfo: const VideoInfo(
        width: 1080,
        height: 1920,
        duration: Duration(milliseconds: 8000),
        fps: 30,
        fileSizeBytes: 1,
      ),
      status: RenewTaskStatus.awaitingCut,
      createdAt: DateTime(2026, 7, 31),
      updatedAt: DateTime(2026, 7, 31),
      units: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 8000,
          transcript: '整段台词',
          shots: [Shot(startMs: 0, endMs: 8000)],
        ),
      ],
    );

void main() {
  group('剪辑快捷键（CLAUDE.md 要求：空格播放、JKL、方向键逐帧）', () {
    late FakePlaybackController playback;

    Future<void> pump(WidgetTester tester) async {
      final repo = _Repo();
      await repo.save(_task());
      playback = FakePlaybackController();
      await tester.pumpWidget(ProviderScope(
        overrides: [taskRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: WorkbenchPage(
            task: _task(),
            playbackFactory: () => playback,
            mediaBuilder: _fakeMediaBuilder(),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('L 播放、K 暂停（视频剪辑通行的 JKL 走带键位）', (tester) async {
      await pump(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(playback.calls, contains('play()'),
          reason: 'L 是所有视频工具里的「播放」键，用户会下意识去按');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pump();
      expect(playback.calls, contains('pause()'));
    });

    testWidgets('J 暂停并后退一帧', (tester) async {
      await pump(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();

      expect(playback.calls, contains('pause()'));
      expect(playback.calls.any((c) => c.startsWith('stepFrames(-1')), isTrue,
          reason: 'J 是反向走带；不支持变速时至少要能逐帧倒退');
    });

    testWidgets('⇧ + 方向键步进 10 帧（粗调）', (tester) async {
      await pump(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();

      expect(playback.calls.any((c) => c.startsWith('stepFrames(10')), isTrue,
          reason: '只有 ±1 帧时，跨过一秒要按 30 次；专业工具都提供粗调档位');
    });

    testWidgets('工具条被按键放行表包裹，方向键不会被页面级快捷键截走',
        (tester) async {
      await pump(tester);

      // 接线断言：缩放滑块所在的工具条外面必须有一层 workbenchControlKeyPassthrough。
      // 不直接模拟"聚焦滑块"是因为 Slider 的内部焦点节点在 widget 测试里拿不稳，
      // 断言会退化成测不到真实路径的假绿（试过，primaryFocus 仍停在 PlayerPanel）。
      final slider = find.byKey(const Key('timeline-zoom-slider'));
      expect(slider, findsOneWidget);

      final guards = tester
          .widgetList<Shortcuts>(
              find.ancestor(of: slider, matching: find.byType(Shortcuts)))
          .where((w) => identical(w.shortcuts, workbenchControlKeyPassthrough));
      expect(guards, isNotEmpty,
          reason: '页面级快捷键的作用域包住了整个 body；工具条不单独放行的话，'
              '焦点落在缩放滑块上时方向键会被截成逐帧步进，'
              '滑块靠方向键微调（macOS 标准行为）就失效了');
    });

    testWidgets('Home / End 跳到片头片尾', (tester) async {
      await pump(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(playback.calls, contains('seekMs(0)'));

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(playback.calls, contains('seekMs(8000)'));
    });
  });

  group('按键放行表的机制本身', () {
    testWidgets('被它包裹的子树里，方向键不再冒泡到外层快捷键', (tester) async {
      var outerInvocations = 0;

      Widget build({required bool withGuard}) {
        final inner = Focus(autofocus: true, child: const SizedBox(width: 40, height: 40));
        return MaterialApp(
          home: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.arrowRight):
                  _ProbeIntent(),
            },
            child: Actions(
              actions: {
                _ProbeIntent: CallbackAction<_ProbeIntent>(
                    onInvoke: (_) => outerInvocations++),
              },
              child: withGuard
                  ? Shortcuts(
                      shortcuts: workbenchControlKeyPassthrough, child: inner)
                  : inner,
            ),
          ),
        );
      }

      // 没有放行表时：外层快捷键会截走方向键
      await tester.pumpWidget(build(withGuard: false));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(outerInvocations, 1, reason: '前提：外层快捷键本来是会生效的');

      // 有放行表时：按键停在这一层，交给控件自己处理
      outerInvocations = 0;
      await tester.pumpWidget(build(withGuard: true));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(outerInvocations, 0,
          reason: '放行表若不起作用，接线断言就只是「包了一层没用的东西」');
    });
  });
}

class _ProbeIntent extends Intent {
  const _ProbeIntent();
}
