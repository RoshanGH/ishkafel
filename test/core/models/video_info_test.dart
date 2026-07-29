import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/video_info.dart';

/// ffprobe -show_streams -show_format 的真实输出结构（节选）
const ffprobeJson = {
  'streams': [
    {'codec_type': 'video', 'width': 1080, 'height': 1920, 'r_frame_rate': '30/1'},
    {'codec_type': 'audio'},
  ],
  'format': {'duration': '96.233333', 'size': '61988138'},
};

void main() {
  test('从 ffprobe JSON 解析元信息', () {
    final info = VideoInfo.fromFfprobeJson(ffprobeJson);
    expect(info.width, 1080);
    expect(info.height, 1920);
    expect(info.duration.inMilliseconds, 96233);
    expect(info.fps, 30.0);
    expect(info.fileSizeBytes, 61988138);
    expect(info.isPortrait, true);
  });

  test('r_frame_rate 分数形式正确换算', () {
    final json = {
      'streams': [
        {'codec_type': 'video', 'width': 1920, 'height': 1080, 'r_frame_rate': '30000/1001'},
      ],
      'format': {'duration': '10.0', 'size': '1'},
    };
    final info = VideoInfo.fromFfprobeJson(json);
    expect(info.fps, closeTo(29.97, 0.01));
    expect(info.isPortrait, false);
  });

  test('缺少视频流时抛 FormatException', () {
    expect(
      () => VideoInfo.fromFfprobeJson(const {'streams': [], 'format': {}}),
      throwsFormatException,
    );
  });

  test('toJson/fromJson 往返一致', () {
    final info = VideoInfo.fromFfprobeJson(ffprobeJson);
    expect(VideoInfo.fromJson(info.toJson()), info);
  });
}
