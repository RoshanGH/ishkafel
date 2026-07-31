import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/media_tools_locator.dart';
import 'package:ishkafel/core/miaoa/miaoa_account_service.dart';
import 'package:ishkafel/features/home/readiness.dart';
import 'package:ishkafel/features/home/welcome_view.dart';
import 'package:ishkafel/features/home/workflow_steps.dart';

const _toolsOk = MediaToolsStatus(
    ffmpegPath: '/opt/homebrew/bin/ffmpeg',
    ffprobePath: '/opt/homebrew/bin/ffprobe');

const _loggedIn = MiaoaAccountStatus(
    loggedIn: true, maskedAccount: '134****0087', tenantName: '极创美奥');

int _started = 0;
int _openedSettings = 0;

Future<void> _pump(
  WidgetTester tester, {
  MediaToolsStatus? tools = _toolsOk,
  MiaoaAccountStatus? account = _loggedIn,
  bool credentials = true,
}) async {
  _started = 0;
  _openedSettings = 0;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: WelcomeView(
        readiness: Readiness.from(
            mediaTools: tools,
            account: account,
            credentialsReady: credentials),
        onStart: () => _started++,
        onOpenSettings: () => _openedSettings++,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('首屏要先回答「这是什么」', () {
    testWidgets('有产品名与一句话说清它做什么', (tester) async {
      await _pump(tester);

      expect(find.text('ishkafel'), findsOneWidget);
      expect(find.textContaining('画面'), findsWidgets,
          reason: '同事双击打开就用，没人给他做培训。一行灰字「还没有任务」'
              '既不说这是什么，也不说该怎么开始');
    });

    testWidgets('四步流程按术语表命名，且写清每步要做什么', (tester) async {
      await _pump(tester);

      for (final step in workflowSteps) {
        expect(find.text(step.title), findsOneWidget);
        expect(step.detail, isNotEmpty);
      }
      expect(workflowSteps, hasLength(4));
    });

    testWidgets('术语与术语表一致，不自造说法', (tester) async {
      await _pump(tester);

      expect(find.textContaining('台词语义单元'), findsWidgets);
      expect(find.textContaining('视觉镜头'), findsWidgets);
    });
  });

  group('主行动号召', () {
    testWidgets('一个显眼的「导入第一条成片」，点了就走导入', (tester) async {
      await _pump(tester);

      await tester.tap(find.byKey(const Key('welcome-start')));
      await tester.pumpAndSettle();

      expect(_started, 1);
    });

    testWidgets('缺 ffmpeg 时按钮禁用，并把原因写在旁边', (tester) async {
      await _pump(tester, tools: const MediaToolsStatus());

      final button =
          tester.widget<FilledButton>(find.byKey(const Key('welcome-start')));
      expect(button.onPressed, isNull);
      expect(find.textContaining('ffmpeg'), findsWidgets,
          reason: '按钮点不动又不说为什么，用户只会以为软件坏了');
    });
  });

  group('准备工作清单', () {
    testWidgets('全部就绪时收成一行，不摆一堆状态灯占地方', (tester) async {
      await _pump(tester);

      expect(find.textContaining('运行环境已就绪'), findsOneWidget);
      expect(find.text('miaoa 账号'), findsNothing,
          reason: '一切正常时把三行检查项摊开，只是在给用户增加噪音');
    });

    testWidgets('有问题时直接摊开，并写清后果与下一步', (tester) async {
      await _pump(tester, account: const MiaoaAccountStatus(loggedIn: false));

      expect(find.text('miaoa 账号'), findsOneWidget);
      expect(find.textContaining('候选素材'), findsWidgets);
      expect(find.textContaining('miaoa auth login'), findsOneWidget);
    });

    testWidgets('检测中不谎报失败', (tester) async {
      await _pump(tester, tools: null, account: null);

      expect(find.textContaining('检测中'), findsWidgets);
      expect(find.textContaining('未安装'), findsNothing);
    });

    testWidgets('清单里能一步跳到设置去核对', (tester) async {
      await _pump(tester, account: const MiaoaAccountStatus(loggedIn: false));

      await tester.tap(find.byKey(const Key('welcome-open-settings')));
      await tester.pumpAndSettle();

      expect(_openedSettings, 1);
    });
  });

  group('使用说明常驻可达', () {
    testWidgets('首屏有入口', (tester) async {
      await _pump(tester);

      expect(find.byKey(const Key('welcome-help')), findsOneWidget);
    });

    testWidgets('点开后能看到四步流程与关键说明', (tester) async {
      await _pump(tester);

      await tester.tap(find.byKey(const Key('welcome-help')));
      await tester.pumpAndSettle();

      expect(find.textContaining('台词与配音不变'), findsWidgets);
      expect(find.text(workflowSteps.last.title), findsWidgets);
    });
  });
}
