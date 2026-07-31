import '../../core/ffmpeg/process_runner.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/net/json_poster.dart';
import '../import_flow/import_exception.dart';

/// 无法归类的分析失败：不暴露异常类名与堆栈，只给用户能据以行动的一句话
const unknownAnalysisErrorMessage = '分析未能完成（内部错误）。请稍后重试；若反复出现，请把日志提供给维护者。';

/// 把分析过程中的异常翻译成可以直接展示给用户的中文。
///
/// 改造前上层用 `error.toString()`，于是 SnackBar 里出现的是
/// `分析失败：AiHttpException(400): ASR 调用失败 [X-Api-Status-Code=45000001]
/// ：Invalid request parameter`——异常类名 + 服务端英文原文；最反讽的是
/// MediaToolMissingException 的 message 本来就是可直接展示的中文安装引导，
/// 却被 toString() 在前面挂了个类名。
///
/// 取值规则：
/// - message 本身就是面向用户的中文（安装引导、导入失败提示）→ 直接用；
/// - message 里混着服务端/ffmpeg 的英文原文 → 换成固定的中文说明，
///   保留排障用得上的结构化信息（HTTP 状态码），英文原文只进日志；
/// - 其余一律落成 [unknownAnalysisErrorMessage]。
///
/// 调用方负责把 [error] 的原始文本写进 AppLog——这里只管展示。
String describeAnalysisError(Object error) => switch (error) {
      // message 已经是可直接展示给用户的安装引导
      MediaToolMissingException(:final message) => message,
      // 导入失败在构造时就已翻译成中文，cause 才是原始异常
      ImportException(:final message) => message,
      FfmpegException() =>
        '视频处理组件未能完成本次操作。请确认素材文件完整、可正常播放后重试。',
      AiHttpException(:final statusCode) => statusCode == null
          ? 'AI 服务调用失败。请检查网络连接与凭据配置后重试。'
          : 'AI 服务调用失败（HTTP $statusCode）。请检查网络连接与凭据配置后重试。',
      MiaoaException() => '素材库服务调用失败。请确认 miaoa 命令行工具可用并已登录后重试。',
      // 上层主动传入的中文原因（如「AI 服务未配置」）原样保留
      String message => message,
      _ => unknownAnalysisErrorMessage,
    };
