import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/ai/ai_credentials.dart';
import '../../core/ai/ark_chat_client.dart';
import '../../core/audio/delivery_analyzer.dart';
import '../../core/audio/tts_client.dart';
import '../../core/audio/voice_swap_job.dart';
export '../../core/audio/voice_swap_job.dart';
import '../../core/audio/voice_swap_service.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';

/// 换音色服务的装配点：把真实的 ffmpeg 切片、ffprobe 量时长、云端客户端接起来。
///
/// null 表示凭据未配置——界面据此把「生成配音」禁用并说明原因，
/// 而不是让用户点了之后撞一个网络错误。
final voiceSwapFactoryProvider = Provider<VoiceSwapFactory?>((ref) => null);
