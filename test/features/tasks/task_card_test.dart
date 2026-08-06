import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/ai/ai_usage.dart';
import 'package:ishkafel/features/tasks/task_card.dart';

RenewTask makeTask({String? coverPath}) => RenewTask(
      id: 'c1',
      name: '滴露_植源喷雾',
      sourcePath: '/v/c1.mp4',
      coverPath: coverPath,
      status: RenewTaskStatus.editing,
      createdAt: DateTime.utc(2026, 7, 29),
      updatedAt: DateTime.utc(2026, 7, 29),
    );

Widget wrapCard(RenewTask task, {bool sourceMissing = false}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 240,
          height: 320,
          child: TaskCard(task: task, sourceMissing: sourceMissing),
        ),
      ),
    );

void main() {
  group('封面渲染不做逐帧同步 IO', () {
    testWidgets('有封面路径就直接交给 Image（不预先 existsSync 探测）', (tester) async {
      await tester.pumpWidget(wrapCard(makeTask(coverPath: '/nope/缺失封面.jpg')));
      await tester.pump();

      expect(find.byType(Image), findsOneWidget,
          reason: 'GridView 滚动时每帧对每张可见卡片做同步 stat 是纯浪费的主线程 IO');
    });

    testWidgets('封面加载失败时回落到黑底占位，不留白', (tester) async {
      await tester.pumpWidget(wrapCard(makeTask(coverPath: '/nope/缺失封面.jpg')));
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.errorBuilder, isNotNull,
          reason: '封面确实可能不存在（源视频被删、抽帧失败），必须有兜底而不是抛红屏');

      // 直接构建失败分支：封面读盘是真实异步 IO，在 widget 测试的假时钟里
      // 等不到失败回调，这里改为验证兜底分支画出来的确实是黑底占位
      final context = tester.element(find.byType(Image));
      await tester.pumpWidget(MaterialApp(
        home: image.errorBuilder!(
            context, const FileSystemException('封面不存在'), null),
      ));
      await tester.pump();

      expect(find.byKey(TaskCard.coverPlaceholderKey), findsOneWidget);
    });

    testWidgets('没有封面路径时直接展示黑底占位', (tester) async {
      await tester.pumpWidget(wrapCard(makeTask()));
      await tester.pump();

      expect(find.byType(Image), findsNothing);
      expect(find.byKey(TaskCard.coverPlaceholderKey), findsOneWidget);
    });
  });

  group('源文件缺失时卡片要说人话', () {
    testWidgets('缺失时给出红色标记与说明文案', (tester) async {
      await tester.pumpWidget(wrapCard(makeTask(), sourceMissing: true));
      await tester.pump();

      expect(find.text('源文件缺失'), findsOneWidget);
      expect(find.textContaining('文件已被移动或删除'), findsOneWidget);
    });

    testWidgets('源文件正常时不出现任何缺失标记', (tester) async {
      await tester.pumpWidget(wrapCard(makeTask()));
      await tester.pump();

      expect(find.text('源文件缺失'), findsNothing);
      expect(find.textContaining('文件已被移动或删除'), findsNothing);
    });
  });

  group('卡片上要看得到「等了多久、花了多少」', () {
    testWidgets('两个数都显示出来', (tester) async {
      await tester.pumpWidget(wrapCard(makeTask().copyWith(
        firstReadyMs: 33400,
        aiUsage: AiUsage.empty.plus(
            model: 'doubao-seed-2-0-mini-260428',
            promptTokens: 120000,
            completionTokens: 8000),
      )));

      expect(find.text('等待 33 秒'), findsOneWidget);
      expect(find.text('¥0.040'), findsOneWidget);
    });

    testWidgets('还没分析完的任务不摆空占位', (tester) async {
      await tester.pumpWidget(wrapCard(makeTask()));

      expect(find.byKey(const Key('task-card-waited')), findsNothing);
      expect(find.byKey(const Key('task-card-cost')), findsNothing);
    });

    testWidgets('只有等待时间、还没调过 AI 时只显示等待', (tester) async {
      await tester.pumpWidget(wrapCard(makeTask().copyWith(firstReadyMs: 5000)));

      expect(find.text('等待 5 秒'), findsOneWidget);
      expect(find.byKey(const Key('task-card-cost')), findsNothing,
          reason: '一次都没调用过时摆个 ¥0 只是噪声');
    });
  });
}
