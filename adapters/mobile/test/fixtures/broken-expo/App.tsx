import React from 'react';
import { FlatList, StyleSheet, Text, View } from 'react-native';

// TODO: wire up the real API and remove the hardcoded base URL below.
const API_BASE = 'http://localhost:3000/api';

type User = { id: string; name: string; email: string };

export default function App(): React.ReactElement {
  const [users, setUsers] = React.useState<User[]>([]);

  React.useEffect(() => {
    fetch(`${API_BASE}/users`)
      .then((r) => r.json())
      .then((data) => {
        console.log('fetched users', data);
        setUsers(data);
      })
      .catch(() => {});
  }, []);

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Users</Text>
      <FlatList
        data={users}
        keyExtractor={(u) => u.id}
        renderItem={({ item }) => (
          <Text style={styles.item}>
            {item.name} — {item.email}
          </Text>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, paddingTop: 60, paddingHorizontal: 16 },
  title: { fontSize: 24, fontWeight: 'bold' },
  item: { fontSize: 16, paddingVertical: 8 },
});
