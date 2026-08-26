import 'dart:convert';
import 'dart:io';

/// 用法错误：参数不对、命令不认识
const int exitBadUsage = 2;

/// 找不到：任务、单元、镜头不存在
const int exitNotFound = 3;

/// 被锁住了：别人正在操作这个任务
const int exitLocked = 4;

/// 环境未就绪：缺 AI 凭据、miaoa 不可用、app 没装——Agent 自己修不了，
/// 该把 stderr 的话转给人去补环境，而不是重试
const int exitEnv = 5;

/// 该做的事做了但没成：ASR 识别不出、TTS 念岔、ffmpeg 挂了。
/// 与「用法不对」「找不到」区分开——这一类值得重试，那几类重试也没用
const int exitFailed = 6;

/// 一行一个 JSON，调用方按行读就行。
///
/// 不缩进、不转义中文：这份输出既要给程序读，也要能被人一眼看懂——排查
/// 问题时人是要直接跑这条命令的（这正是选 CLI 而不是 MCP 的理由之一）。
/// `任务` 那种转义等于把报错藏起来。
void emitJson(Object? payload, {StringSink? out}) {
  (out ?? stdout).writeln(jsonEncode(payload));
}

/// 失败时把**能直接展示的中文**写到 stderr 并退出。
///
/// 原始异常报文进日志，不摊给调用方——见 CLAUDE.md：一句能照做的话
/// 比一句吓人的话有用。
Never failWith(String humanReason, {int code = 1, StringSink? err}) {
  (err ?? stderr).writeln(humanReason);
  exit(code);
}
