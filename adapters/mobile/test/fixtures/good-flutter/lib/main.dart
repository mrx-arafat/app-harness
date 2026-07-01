import 'package:flutter/material.dart';

void main() {
  runApp(const TodayApp());
}

/// A small, self-contained to-do screen used as a clean Flutter fixture.
/// Deliberately free of debug prints, hardcoded endpoints, TODOs and empty
/// catches so the quality scanner reports zero hits against it.
class TodayApp extends StatelessWidget {
  const TodayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Today',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2563EB),
        brightness: Brightness.dark,
      ),
      home: const TodayScreen(),
    );
  }
}

class Task {
  const Task(this.id, this.title, {this.done = false});

  final String id;
  final String title;
  final bool done;

  Task toggled() => Task(id, title, done: !done);
}

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  final List<Task> _tasks = <Task>[
    const Task('t1', 'Water the plants'),
    const Task('t2', 'Review the sprint board', done: true),
    const Task('t3', 'Call the dentist'),
  ];

  int get _remaining => _tasks.where((Task t) => !t.done).length;

  void _toggle(String id) {
    setState(() {
      for (int i = 0; i < _tasks.length; i++) {
        if (_tasks[i].id == id) {
          _tasks[i] = _tasks[i].toggled();
          break;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Today'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(_remaining == 0 ? 'All clear' : '$_remaining left'),
            ),
          ),
        ],
      ),
      body: _tasks.isEmpty
          ? const Center(child: Text('Nothing here yet'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _tasks.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (BuildContext context, int index) {
                final Task task = _tasks[index];
                return ListTile(
                  onTap: () => _toggle(task.id),
                  leading: Icon(
                    task.done
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(task.title),
                );
              },
            ),
    );
  }
}
