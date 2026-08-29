/// `ishkafel` 认得的所有顶层命令。
///
/// 单独列出来是为了**盯住文档**：手册里写了 `ishkafel voices`，而那条命令
/// 一直不存在——验收 Agent 照做，拿到「未知命令」，于是既不能自己挑音色
/// （手册禁止）、也没法把选项列给人看，整条配音链路在纯 CLI 下是死的。
///
/// 照着不存在的命令走，Agent 会以为是**环境坏了**，而不是文档错了。
/// 有架构测试拿这份清单去对手册（test/architecture/agent_parity_test.dart）。
const List<String> topLevelCommands = [
  'analyze',
  'apply',
  'blank',
  'candidates',
  'doctor',
  'export',
  'import',
  'jianying',
  'open',
  'peek',
  'review',
  'script',
  'skill',
  'subtitle',
  'tag-groups',
  'task',
  'task-delete',
  'task-rename',
  'tasks',
  'todo',
  'ui',
  'voices',
];
