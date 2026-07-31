import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_providers.dart';
import '../tasks/environment_banner.dart';
import '../tasks/task_list_controller.dart';
import 'readiness.dart';

/// 首页「准备工作」清单。
///
/// 三项来源各不相同，在这里汇成一份：
/// - 视频组件：启动期 preflight 的结果（main.dart override）
/// - miaoa 账号：设置页那条 `auth status`，共用同一个 provider 免得跑两遍
/// - 云端凭据：分析管线是否装配成功——凭据不全时它就是 null，
///   这是现成且不会说谎的信号，比再读一遍凭据可靠
final readinessProvider = Provider<Readiness>((ref) => Readiness.from(
      mediaTools: ref.watch(mediaToolsStatusProvider),
      account: ref.watch(miaoaAccountProvider).valueOrNull,
      credentialsReady: ref.watch(analysisPipelineProvider) != null,
    ));
