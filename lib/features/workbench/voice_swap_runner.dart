import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/voice_swap_job.dart';
export '../../core/audio/voice_swap_job.dart';

/// 换音色服务的装配点：把真实的 ffmpeg 切片、ffprobe 量时长、云端客户端接起来。
///
/// null 表示凭据未配置——界面据此把「生成配音」禁用并说明原因，
/// 而不是让用户点了之后撞一个网络错误。
final voiceSwapFactoryProvider = Provider<VoiceSwapFactory?>((ref) => null);
