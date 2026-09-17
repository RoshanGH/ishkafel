import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';

/// Agent 请界面**代办**一件事。
///
/// 与在场状态（[AgentPresence]）方向相同、语义相反：那是通报「我在做什么」，
/// 这是请求「你替我做」。
///
/// 存在理由是一条真实场景：**人正开着界面看着指挥它**。这时界面持着会话锁，
/// Agent 写不进去——但这不该是错误，因为人要的正是让它动手。而且直接写盘
/// 也是错的：审片台上剔掉的卡只是界面里的临时状态，人按「确认」才落盘，
/// Agent 绕过界面写盘，会让人还没确认盘上就变了。
///
/// 所以规矩是：**界面在场时，写操作委派给界面**。同一份状态、同一条落盘
/// 路径，人看到的和最终结果永远一致。
class AgentRequest {
  /// 请求 id，回执按它配对——不然上一轮的回执会被当成这一轮的
  final String id;

  /// 干什么：`review.drop` / `review.keep`
  final String kind;

  /// 参数，按 [kind] 约定
  final Map<String, dynamic> payload;

  final DateTime at;

  const AgentRequest({
    required this.id,
    required this.kind,
    required this.payload,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'payload': payload,
        'at': at.toIso8601String(),
      };

  static AgentRequest? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final kind = raw['kind'];
    if (id is! String || id.isEmpty || kind is! String || kind.isEmpty) {
      return null;
    }
    return AgentRequest(
      id: id,
      kind: kind,
      payload: raw['payload'] is Map
          ? Map<String, dynamic>.from(raw['payload'] as Map)
          : const {},
      at: DateTime.tryParse('${raw['at']}') ?? DateTime.now(),
    );
  }
}

/// 界面干完之后的回执。**失败也要如实说原因**——Agent 得把它原样转给人
class AgentRequestResult {
  final String id;
  final bool ok;
  final String message;

  /// 界面干完之后要带回来的事实——**比如它到底建出了哪条任务**。
  ///
  /// 以前没有这一层：`ui new-task` 只能建完之后去任务库里翻「创建时间最新的
  /// 那条」，代码注释自己都写着「不给的话只能去 tasks 里翻最后一条猜」。
  /// 真机上那一猜就出事了：授权框把创建挡住、任务压根没建成，
  /// CLI 却把上一次的任务报了出来还说「已经建好了」。
  final Map<String, dynamic> payload;

  /// **这一页压根接不了这个动作**（不是「试了没做成」）。
  ///
  /// 这两件事在 [ok] 这一个布尔上分不开，而它们该走完全相反的两条路：
  ///
  /// - **内容类拒绝**（「这一页上没有这些候选」「方案对不上现在的切分」）
  ///   是**真事实**，调用方该原样把理由带回去，不许兜底改成成功
  /// - **在场类拒绝**（「审核页不认识 export.open」）说的只是
  ///   「人恰好开着另一页」——那跟 Agent 能不能干这件事毫无关系。
  ///   把它当失败，就又变成了「我做不了，因为软件那边不让」
  ///
  /// 所以各页面对**认不出的 kind** 一律带上这个标记，调用方读到它就当
  /// 「没人接」处理：自己干（见 `lib/cli/delegate.dart`）。
  final bool unsupported;

  const AgentRequestResult({
    required this.id,
    required this.ok,
    required this.message,
    this.payload = const {},
    this.unsupported = false,
  });
}

File _requestFile(Directory dataDir, String taskId) =>
    File(p.join(dataDir.path, 'presence', '$taskId.request.json'));

File _resultFile(Directory dataDir, String taskId) =>
    File(p.join(dataDir.path, 'presence', '$taskId.request-result.json'));

/// 下单。返回请求 id，用它等回执
String writeAgentRequest({
  required Directory dataDir,
  required String taskId,
  required String kind,
  required Map<String, dynamic> payload,
  String? id,
}) {
  final at = DateTime.now();
  final requestId = id ?? '$kind-${at.microsecondsSinceEpoch}';
  try {
    // 上一轮的回执先清掉：不然新请求一进来就读到旧回执
    final stale = _resultFile(dataDir, taskId);
    if (stale.existsSync()) stale.deleteSync();
    final f = _requestFile(dataDir, taskId);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode(AgentRequest(
      id: requestId,
      kind: kind,
      payload: payload,
      at: at,
    ).toJson()));
  } catch (e) {
    AppLog.warn('代办请求写入失败（$taskId）：$e');
  }
  return requestId;
}

/// 界面取单：**读到即删**，同一条请求只执行一次。
/// 读不懂的也删掉——留着的话每轮都会重读同一个坏文件
AgentRequest? consumeAgentRequest({
  required Directory dataDir,
  required String taskId,
}) {
  final f = _requestFile(dataDir, taskId);
  try {
    if (!f.existsSync()) return null;
    final raw = f.readAsStringSync();
    f.deleteSync();
    return AgentRequest.tryFromJson(jsonDecode(raw));
  } catch (e) {
    AppLog.warn('代办请求读取失败（$taskId）：$e');
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    return null;
  }
}

/// 界面交活
void writeAgentRequestResult({
  required Directory dataDir,
  required String taskId,
  String? id,
  bool? ok,
  String? message,
  AgentRequestResult? result,
  Map<String, dynamic> payload = const {},

  /// 这一页压根接不了这个动作。见 [AgentRequestResult.unsupported]
  bool unsupported = false,
}) {
  final r = result ??
      AgentRequestResult(
          id: id!,
          ok: ok!,
          message: message!,
          payload: payload,
          unsupported: unsupported);
  try {
    final f = _resultFile(dataDir, taskId);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({
      'id': r.id,
      'ok': r.ok,
      'message': r.message,
      if (r.payload.isNotEmpty) 'payload': r.payload,
      // 默认值不写进文件：老版本的界面读到陌生的键也不会怎样，
      // 但少写一个键就少一处要维护的兼容
      if (r.unsupported) 'unsupported': true,
    }));
  } catch (e) {
    AppLog.warn('代办回执写入失败（$taskId）：$e');
  }
}

/// Agent 等界面把这件事干完。
///
/// 与展示回执（[waitForAck]）的超时语义**相反**：那边超时只是没人看见，
/// 照常往下跑；这边超时意味着**活儿根本没干**，必须当失败处理，
/// 不能报成功
Future<AgentRequestResult?> waitForAgentRequest({
  required Directory dataDir,
  required String taskId,
  required String id,
  Duration timeout = const Duration(seconds: 20),
  Duration poll = const Duration(milliseconds: 80),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final got = _readResult(dataDir: dataDir, taskId: taskId);
    // id 对不上说明这是上一轮留下的，继续等
    if (got != null && got.id == id) return got;
    await Future<void>.delayed(poll);
  }
  return null;
}

AgentRequestResult? _readResult({
  required Directory dataDir,
  required String taskId,
}) {
  try {
    final f = _resultFile(dataDir, taskId);
    if (!f.existsSync()) return null;
    final raw = jsonDecode(f.readAsStringSync());
    if (raw is! Map || raw['id'] is! String) return null;
    return AgentRequestResult(
      id: raw['id'] as String,
      ok: raw['ok'] == true,
      message: raw['message'] is String ? raw['message'] as String : '',
      // 老回执没有这几个字段——不能因为多个字段就读不回来
      payload: raw['payload'] is Map
          ? Map<String, dynamic>.from(raw['payload'] as Map)
          : const {},
      unsupported: raw['unsupported'] == true,
    );
  } catch (_) {
    return null;
  }
}
