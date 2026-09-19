/// **别把同一件贵活儿跑两遍——但这是劝告，不是拒绝。**
///
/// 删掉任务锁之后，「调用方的命令超时了、以为失败又起一个」这件事没人挡了。
/// 对**逐项**的活儿（配音、参考镜打标），每一项开工前重读盘、做过的跳过就够，
/// 那是真幂等。但它只挡得住「对方跑在前面」那一半：
///
/// > 进程 1 跑到第 12 句。进程 2 起来，跳过 1–11，**从第 12 句开始**。
/// > 两个都重读、都看到「还不是 fresh」（进程 1 还没合成完）→ 都调 TTS。
/// > 写完各自进第 13 句……**剩下 13 句全部念两遍。**
///
/// 而「超时重试」恰恰是这个同速场景。所以在**命令级**再加一道：发现另一个
/// 进程正在这条任务上干同一类活儿，就什么都不做、如实说一句、给出 `--force`。
///
/// **为什么这不违反「软件永远不对 Agent 说不行」**（这一条要分清楚）：
///
/// - 它**没有拒绝**——退出码 0，`ok: true`
/// - 它报的是**事实**（「另一个进程正在做，我没有重复做」），不是规则
/// - `--force` 这条明路写在输出里，**决定权仍在 Agent 手上**
///
/// 产品负责人的原话：「任何它不应该做的事情，都应该是人告诉 Agent 的，
/// 而非是软件限制的。」给事实和出路，不给规则。
library;

import 'dart:io';

import '../core/storage/agent_presence.dart';

/// 「正在分析」这一类活儿的关键词。
///
/// **判据和播报文案必须引用同一份常量。** 判「有没有人在干同一件事」靠的是
/// 在场状态的 `action` 里有没有这几个字——而那句 `action` 是各命令自己拼的。
/// 手写的话，哪天有人把开工那句改成「这一轮 20 句要念」，判据当场失效，
/// **而所有测试照样全绿**（评审原话）。引用同一个常量，改文案就会编译期
/// 或测试期暴露出来。
const String analyzeBusyKeyword = '分析';

/// 「正在配音」这一类
const String voiceBusyKeyword = '配音';

/// 「正在打标」这一类（参考镜识图）
const String tagBusyKeyword = '打标';

/// 这条任务上是不是已经有**另一个进程**在干同一类活儿。
///
/// 判据就是 Agent 的在场状态：谁在、在干什么。**心跳新不新鲜用现成的
/// [defaultStaleAfter]**（`readAgentPresence` 自己按它判），不另发明一个
/// 时限——两套时限迟早对不上，而对不上的那一天没人看得出来。
///
/// [keywords] 里任意一个命中在场状态的 `action` 就算同一类活儿。
/// 只认同类：同一条任务上对方可能正在挑镜头、正在配乐，那些跟这件事
/// 没关系，拦它是白拦。
AgentPresence? someoneElseBusyWith({
  required Directory dataDir,
  required String taskId,
  required List<String> keywords,
  DateTime? now,
}) {
  // **两份都要看。**
  //
  // Agent 的在场状态（播报通道那一份）和**软件自己在忙**的那一份是两个文件
  // ——分开是因为播报只该报 Agent（CLAUDE.md 明令），**不是因为判据可以
  // 装作看不见软件那一边**。这道劝告存在的理由之一就是拦住「人在界面上点了
  // 分析 + Agent 同时 analyze」，漏掉软件那份等于把它弄瞎。
  for (final busy in [
    readAgentPresence(dataDir: dataDir, taskId: taskId, now: now),
    readAppBusy(dataDir: dataDir, taskId: taskId, now: now),
  ]) {
    if (busy == null) continue;
    for (final word in keywords) {
      if (busy.action.contains(word)) return busy;
    }
  }
  return null;
}

/// 那句「劝告」的 JSON。
///
/// `skipped` **必须是 JSON 里的一个字段**：Agent 是按 JSON 判断的，
/// 只在 stderr 说一句它读不到，照样会以为活儿干完了。
Map<String, dynamic> busySkipReport({
  required String taskId,
  required AgentPresence busy,
  required String what,
}) =>
    {
      'ok': true,
      'skipped': true,
      'taskId': taskId,
      'reason': '另一个进程正在$what这条任务'
          '（正在：${busy.action.isEmpty ? '没说' : busy.action}）',
      'hint': '要强制重跑加 --force',
    };
