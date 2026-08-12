import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/environment_report.dart';
import '../../core/diagnostics/tool_installer.dart';
import '../../core/miaoa/miaoa_account_service.dart';
import '../../core/miaoa/miaoa_auth_service.dart';
import '../../core/storage/cache_usage.dart';
import '../../core/storage/task_repository.dart';
import '../tasks/task_list_controller.dart';

/// 应用版本号。`pubspec.yaml` 的值不能在运行时读到（打包后没有这个文件），
/// 又不值得为一行字引入 package_info_plus——因此在这里写一份，用测试盯住
/// 它和 pubspec 不漂移。
const String appVersion = '0.1.5';

/// 终端登录命令：三处（未登录提示、复制按钮、失败引导）共用一份，
/// 免得改了一处另两处还在教用户敲旧命令
const String miaoaLoginCommand = 'miaoa auth login';

// ── 注入点 ────────────────────────────────────────────────
// 默认值都是「不可用」而非可用的真实实现：单测里不会有任何一条命令被真的
// 执行，也不会有任何目录被真的扫描。真实实现由 main.dart override。

final miaoaAccountServiceProvider =
    Provider<MiaoaAccountService?>((ref) => null);

/// 登录/登出。null 表示本次运行没接入——设置页那时退回「去终端登录」的引导，
/// 而不是给一个点了没反应的按钮
final miaoaAuthServiceProvider = Provider<MiaoaAuthService?>((ref) => null);

/// 一键安装外部依赖。null 表示本次运行没接入——那时设置页退回「请在终端
/// 执行……」的引导，而不是给一个点了没反应的按钮
final toolInstallerProvider = Provider<ToolInstaller?>((ref) => null);

final cacheScannerProvider = Provider<CacheScanner?>((ref) => null);

final environmentProbeProvider = Provider<EnvironmentProbe?>((ref) => null);

final dataDirProvider = Provider<Directory?>((ref) => null);

/// 执行清理并返回实际释放的字节数（抽成 provider 是为了让页面测试无需真实文件系统）
typedef CachePurge = Future<int> Function();

final cachePurgeProvider = Provider<CachePurge>((ref) {
  final scanner = ref.watch(cacheScannerProvider);
  final repository = ref.watch(taskRepositoryProvider);
  return () async {
    if (scanner == null) return 0;
    return scanner.purgeOrphans(knownTaskIds: await _knownTaskIds(repository));
  };
});

// ── 读取 ────────────────────────────────────────────────

/// null 表示本次运行没有接入账号服务（只会发生在测试环境）。
/// 不拿「未登录」冒充它——那会在 main.dart 漏接线时，让已登录的用户
/// 永远看到一份登录引导，而没有任何线索指向真正的原因。
final miaoaAccountProvider = FutureProvider<MiaoaAccountStatus?>(
    (ref) => ref.watch(miaoaAccountServiceProvider)?.fetch());

/// 缓存占用。孤儿判定要拿现存任务 id，因此依赖任务仓库；
/// 删除任务后 invalidate 本 provider 即可让占用数字跟上。
final cacheUsageProvider = FutureProvider<CacheUsage>((ref) async {
  final scanner = ref.watch(cacheScannerProvider);
  if (scanner == null) return CacheUsage.empty;
  return scanner.scan(
      knownTaskIds: await _knownTaskIds(ref.watch(taskRepositoryProvider)));
});

final environmentReportProvider = FutureProvider<EnvironmentReport?>((ref) {
  final probe = ref.watch(environmentProbeProvider);
  return probe?.collect();
});

Future<Set<String>> _knownTaskIds(TaskRepository repository) async =>
    {for (final task in await repository.findAll()) task.id};
