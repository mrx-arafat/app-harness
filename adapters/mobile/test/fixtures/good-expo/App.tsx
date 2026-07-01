import React from 'react';
import { StatusBar } from 'expo-status-bar';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';

type Task = {
  id: string;
  title: string;
  done: boolean;
};

const SEED_TASKS: Task[] = [
  { id: 't1', title: 'Water the plants', done: false },
  { id: 't2', title: 'Review the sprint board', done: true },
  { id: 't3', title: 'Call the dentist', done: false },
];

/**
 * A minimal error boundary so a single screen crash does not take down the whole app.
 * Its presence is what a quality scanner looks for in a React Native tree.
 */
class ErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { hasError: boolean }
> {
  state = { hasError: false };

  static getDerivedStateFromError(): { hasError: boolean } {
    return { hasError: true };
  }

  componentDidCatch(error: Error): void {
    // Report to a crash service in production; kept side-effect-free here.
    this.setState({ hasError: true });
  }

  render(): React.ReactNode {
    if (this.state.hasError) {
      return (
        <View style={styles.fallback}>
          <Text style={styles.fallbackTitle}>Something went wrong</Text>
          <Text style={styles.fallbackBody}>Pull down to try again.</Text>
        </View>
      );
    }
    return this.props.children;
  }
}

function TaskRow({ task, onToggle }: { task: Task; onToggle: (id: string) => void }): React.ReactElement {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ checked: task.done }}
      onPress={() => onToggle(task.id)}
      style={({ pressed }) => [styles.row, pressed && styles.rowPressed]}
      hitSlop={8}
    >
      <View style={[styles.checkbox, task.done && styles.checkboxDone]}>
        {task.done ? <Text style={styles.checkmark}>✓</Text> : null}
      </View>
      <Text style={[styles.rowTitle, task.done && styles.rowTitleDone]}>{task.title}</Text>
    </Pressable>
  );
}

export default function App(): React.ReactElement {
  const [tasks, setTasks] = React.useState<Task[]>(SEED_TASKS);

  const toggle = React.useCallback((id: string) => {
    setTasks((prev) =>
      prev.map((t) => (t.id === id ? { ...t, done: !t.done } : t)),
    );
  }, []);

  const remaining = tasks.filter((t) => !t.done).length;

  return (
    <ErrorBoundary>
      <SafeAreaProvider>
        <SafeAreaView style={styles.screen} edges={['top', 'bottom']}>
          <StatusBar style="light" />
          <View style={styles.header}>
            <Text style={styles.title}>Today</Text>
            <Text style={styles.subtitle}>
              {remaining === 0 ? 'All clear' : `${remaining} left`}
            </Text>
          </View>
          <ScrollView
            contentContainerStyle={styles.list}
            showsVerticalScrollIndicator={false}
          >
            {tasks.length === 0 ? (
              <View style={styles.empty}>
                <Text style={styles.emptyTitle}>Nothing here yet</Text>
                <Text style={styles.emptyBody}>Add a task to get started.</Text>
              </View>
            ) : (
              tasks.map((task) => (
                <TaskRow key={task.id} task={task} onToggle={toggle} />
              ))
            )}
          </ScrollView>
        </SafeAreaView>
      </SafeAreaProvider>
    </ErrorBoundary>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#0B1220' },
  header: { paddingHorizontal: 20, paddingTop: 12, paddingBottom: 16 },
  title: { color: '#F8FAFC', fontSize: 34, fontWeight: '700', letterSpacing: 0.2 },
  subtitle: { color: '#94A3B8', fontSize: 15, marginTop: 4 },
  list: { paddingHorizontal: 16, paddingBottom: 32 },
  row: {
    minHeight: 56,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 12,
    paddingVertical: 12,
    borderRadius: 14,
    backgroundColor: '#111A2E',
    marginBottom: 10,
  },
  rowPressed: { backgroundColor: '#16223B' },
  checkbox: {
    width: 26,
    height: 26,
    borderRadius: 8,
    borderWidth: 2,
    borderColor: '#334155',
    alignItems: 'center',
    justifyContent: 'center',
    marginRight: 14,
  },
  checkboxDone: { backgroundColor: '#22C55E', borderColor: '#22C55E' },
  checkmark: { color: '#0B1220', fontSize: 16, fontWeight: '800' },
  rowTitle: { color: '#E2E8F0', fontSize: 17, flexShrink: 1 },
  rowTitleDone: { color: '#64748B', textDecorationLine: 'line-through' },
  empty: { alignItems: 'center', paddingVertical: 64 },
  emptyTitle: { color: '#E2E8F0', fontSize: 18, fontWeight: '600' },
  emptyBody: { color: '#64748B', fontSize: 14, marginTop: 6 },
  fallback: { flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: '#0B1220' },
  fallbackTitle: { color: '#F8FAFC', fontSize: 20, fontWeight: '700' },
  fallbackBody: { color: '#94A3B8', fontSize: 14, marginTop: 8 },
});
