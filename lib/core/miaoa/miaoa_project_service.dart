import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import 'miaoa_errors.dart';
import 'miaoa_locator.dart';
import 'miaoa_tag_service.dart' show MiaoaException;

/// miaoa 里的一个项目（素材按项目归属）
class MiaoaProject {
  final int id;
  final String name;

  const MiaoaProject({required this.id, required this.name});

  /// 宽松解析：一条畸形只跳过它，不因为一个坏条目让整份项目列表读不出来
  static MiaoaProject? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! int || name is! String || name.isEmpty) return null;
    return MiaoaProject(id: id, name: name);
  }
}

/// 项目列表（走 miaoa CLI 子进程）。
///
/// 检索时用它把范围收到一个项目内：素材库里四万多条分镜横跨几十个项目，
/// 不限项目搜出来的东西大多不是这条片子能用的。
class MiaoaProjectService {
  final ProcessRunner run;
  final String binary;

  /// [binary] 缺省即解析真实安装路径，理由见 MiaoaContentService
  MiaoaProjectService({this.run = systemProcessRunner, String? binary})
      : binary = binary ?? resolveMiaoaBinary();

  /// 一次取回全部项目。
  ///
  /// 只要启用中的：停用的项目不会再有新素材进来，摆在选择列表里只会让人
  /// 多翻几屏。page-size 给足，几十个项目一页装得下——分页翻起来反而更慢。
  Future<List<MiaoaProject>> listProjects() async {
    final result = await run(binary, [
      'project',
      'list',
      '--enabled-only',
      '--page-size',
      '200',
      '--json',
    ]);
    if (result.exitCode != 0) {
      throw MiaoaException(
          miaoaFriendlyError(result.exitCode, '${result.stderr}'));
    }

    final decoded = _decode('${result.stdout}');
    final records = decoded['records'];
    if (records is! List) {
      throw const MiaoaException('项目列表返回的数据格式无法识别，请稍后重试');
    }
    final projects = [
      for (final r in records) ?MiaoaProject.tryFromJson(r),
    ];
    final skipped = records.length - projects.length;
    if (skipped > 0) AppLog.warn('项目列表里有 $skipped 条无法解析，已跳过');
    return List.unmodifiable(projects);
  }

  Map<String, dynamic> _decode(String stdout) {
    try {
      final decoded = jsonDecode(stdout.trim());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      AppLog.warn('项目列表返回的不是 JSON：$e');
    }
    throw const MiaoaException('项目列表返回的数据格式无法识别，请稍后重试');
  }
}

/// 默认构造不会启动子进程（只有真正调 listProjects 时才 exec），
/// 所以这里给真实实现是安全的；单测一律 override。
final miaoaProjectServiceProvider = Provider<MiaoaProjectService>(
    (ref) => MiaoaProjectService(binary: resolveMiaoaBinary()));
