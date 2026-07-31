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

  group('帧率解析（部分容器会把 r_frame_rate 报成 0/0）', () {
    Map<String, dynamic> jsonWith({dynamic rFrameRate, dynamic avgFrameRate}) =>
        {
          'streams': [
            {
              'codec_type': 'video',
              'width': 1080,
              'height': 1920,
              'r_frame_rate': ?rFrameRate,
              'avg_frame_rate': ?avgFrameRate,
            },
          ],
          'format': {'duration': '10.0', 'size': '1'},
        };

    test('r_frame_rate 为 0/0 时回退 avg_frame_rate', () {
      final info =
          VideoInfo.fromFfprobeJson(jsonWith(rFrameRate: '0/0', avgFrameRate: '25/1'));
      expect(info.fps, 25.0);
    });

    test('r_frame_rate 为空字符串时回退 avg_frame_rate（29.97 分数形式）', () {
      final info = VideoInfo.fromFfprobeJson(
          jsonWith(rFrameRate: '', avgFrameRate: '30000/1001'));
      expect(info.fps, closeTo(29.97, 0.01));
    });

    test('r_frame_rate 字段缺失（null）时回退 avg_frame_rate', () {
      final info = VideoInfo.fromFfprobeJson(jsonWith(avgFrameRate: '30/1'));
      expect(info.fps, 30.0);
    });

    test('两者都是 0/0 时抛 FormatException，绝不返回 0 帧率', () {
      expect(
        () => VideoInfo.fromFfprobeJson(
            jsonWith(rFrameRate: '0/0', avgFrameRate: '0/0')),
        throwsFormatException,
      );
    });

    test('两者都缺失时抛 FormatException', () {
      expect(() => VideoInfo.fromFfprobeJson(jsonWith()), throwsFormatException);
    });

    test('r_frame_rate 为非数字文本时抛 FormatException', () {
      expect(() => VideoInfo.fromFfprobeJson(jsonWith(rFrameRate: 'N/A')),
          throwsFormatException);
    });

    test('r_frame_rate 合法时不看 avg_frame_rate', () {
      final info = VideoInfo.fromFfprobeJson(
          jsonWith(rFrameRate: '30/1', avgFrameRate: '0/0'));
      expect(info.fps, 30.0);
    });

    test('负帧率同样视为非法', () {
      expect(() => VideoInfo.fromFfprobeJson(jsonWith(rFrameRate: '-30/1')),
          throwsFormatException);
    });
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
