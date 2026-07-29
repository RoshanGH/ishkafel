import 'package:flutter/material.dart';
import '../features/tasks/task_list_page.dart';
import 'theme/app_theme.dart';

class IshkafelApp extends StatelessWidget {
  const IshkafelApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ishkafel',
        theme: buildAppTheme(),
        debugShowCheckedModeBanner: false,
        home: const TaskListPage(),
      );
}
