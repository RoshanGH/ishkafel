import 'dart:io';
import 'dart:typed_data';

/// 把一个地址整段读成字节。
///
/// 只用于**小文件**（缩略图这类）。视频/音频要落地请走各自的缓存
/// （`BgmCache`、`MaterialDownloader`）——那两处是边下边写文件，
/// 不会把几十兆整个读进内存。
Future<List<int>> httpBytes(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    final chunks = <int>[];
    await for (final chunk in response) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  } finally {
    client.close(force: true);
  }
}
