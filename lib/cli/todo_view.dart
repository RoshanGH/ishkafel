import '../core/analysis/providers.dart';
import '../core/models/renew_task.dart';

/// 交给调用方的一件待办：**输入、要它做什么、做完怎么交回来**，一次说清。
///
/// 三样缺一不可。只给输入不说怎么交回来，它得去翻文档；只说做什么不给输入，
/// 它得自己去别处捞——两种都会变成来回试。
Map<String, dynamic> segmentTodo(String taskId, List<AsrSentence> sentences) => {
      'status': 'pending',
      'todo': {
        'kind': 'segment',
        'why': '把台词切成语义单元：一段完整意思算一个，可能一句也可能几句',
        'rules': [
          '单元必须首尾相接、覆盖全部句子——漏一句或算两次都会让台词与画面错位',
          'fromSentence / toSentence 是句子下标，含两端',
          '不要改台词文本：怎么分组归你，内容是 ASR 的产出',
        ],
        'input': {
          'sentences': [
            for (var i = 0; i < sentences.length; i++)
              {
                'index': i,
                'startMs': sentences[i].startMs,
                'endMs': sentences[i].endMs,
                'text': sentences[i].text,
              },
          ],
        },
        'apply': 'ishkafel apply segment $taskId --file <结果.json>',
        'shape': {
          'units': [
            {'fromSentence': 0, 'toSentence': 2},
            {'fromSentence': 3, 'toSentence': 3},
          ],
        },
      },
    };

/// 打标的待办。
///
/// **受控词表要一起给**：标签必须从里面选，不在词表里的会被拒。词表是标签组
/// 下的**标签**，不是标签组的名字——给错了调用方会打出一批全被拒绝的标签，
/// 而它无从知道自己错在哪。
Map<String, dynamic> tagTodo(
  String taskId,
  RenewTask task, {
  required List<String> unitVocabulary,
  required List<String> shotVocabulary,
}) => {
      'status': 'pending',
      'todo': {
        'kind': 'tag',
        'why': '给每个台词语义单元与视觉镜头贴标签。标签是后面检索替换素材的依据',
        'rules': [
          '只能用下面 vocabulary 里的词，一个字都不能差——'
              '「厨房场景」和「厨房情景」在检索时是两回事',
          '拿不准就少打：错的标签会检索出一批不相干的素材',
          // 镜头标签讲的是画面里有什么，光看时间戳和台词是打不出来的
          '镜头标签**必须看过画面再打**：从 sourcePath 按 sampleAt 抽帧看，'
              '例如 ffmpeg -ss <秒> -i <sourcePath> -frames:v 1 <输出.jpg>',
        ],
        'input': {
          'sourcePath': task.sourcePath,
          'unitVocabulary': unitVocabulary,
          'shotVocabulary': shotVocabulary,
          'units': [
            for (final unit in task.units ?? const [])
              {
                'index': unit.index,
                'transcript': unit.transcript,
                'shots': [
                  for (var s = 0; s < unit.shots.length; s++)
                    {
                      'index': s,
                      'startMs': unit.shots[s].startMs,
                      'endMs': unit.shots[s].endMs,
                      // 抽帧点给中点：起止两端常常正踩在转场上，抽出来是糊的
                      'sampleAtSec':
                          (unit.shots[s].startMs + unit.shots[s].endMs) /
                              2000.0,
                      'description': unit.shots[s].description,
                    },
                ],
              },
          ],
        },
        'apply': 'ishkafel apply tags $taskId --file <结果.json>',
        'shape': {
          'units': [
            {
              'unit': 0,
              'tags': ['促单'],
              'shots': {
                '0': ['厨房情景'],
              },
            },
          ],
        },
      },
    };
