/// 一帧的画面变化信号（相对前一帧）。
///
/// 两个指标互补，缺一不可：
/// - [sceneScore]：ffmpeg 的相邻帧差分，衡量「动得多剧烈」。硬切最敏感，
///   但画面里手快速移动同样能冲高。
/// - [histDistance]：颜色直方图的 L1 距离，衡量「颜色分布换没换」。
///   镜头内运动几乎不改变分布，换机位则突变——这是把「动」和「切」分开的
///   物理依据。
class FrameSignal {
  final int ms;
  final double sceneScore;
  final double histDistance;

  const FrameSignal({
    required this.ms,
    required this.sceneScore,
    required this.histDistance,
  });
}

/// 直方图分箱数：RGB 三通道各 8 档。
///
/// 8 档是刻意取小的：档位越细越容易被噪点和轻微光线变化拉开距离，而我们要
/// 判的是「换场景没有」这种粗粒度的事。
const int histBinsPerChannel = 8;
const int histBins = histBinsPerChannel * 3;

/// 由 32×32 RGB24 缩略图算归一化直方图。
///
/// 缩到 32×32 是刻意的：分辨率越低越不受运动细节影响，只留下色彩构成——
/// 恰好是我们要比较的东西，顺带让整片的逐帧特征只有几 MB。
List<double> histogramOfRgb24(List<int> bytes, {int side = 32}) {
  final counts = List<double>.filled(histBins, 0);
  final pixels = side * side;
  for (var p = 0; p + 2 < bytes.length; p += 3) {
    counts[bytes[p] >> 5] += 1;
    counts[histBinsPerChannel + (bytes[p + 1] >> 5)] += 1;
    counts[histBinsPerChannel * 2 + (bytes[p + 2] >> 5)] += 1;
  }
  if (pixels <= 0) return counts;
  return [for (final c in counts) c / pixels];
}

/// 两个归一化直方图的距离：三通道 L1 距离之和再除以 3（即三通道的平均
/// L1 距离），取值 0~2——2 出现在纯黑对纯白这种极端。实测真实素材上
/// p99 落在 0.47~0.56，真实镜头切换在 0.49 以上。
double histogramDistance(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / 3;
}
