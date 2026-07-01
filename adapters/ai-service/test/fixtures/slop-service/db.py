# Planted Python-flavored SQL injection smells for quality.mjs.


def get_user(conn, user_id):
    # planted: f-string SQL injection
    query = f"SELECT * FROM users WHERE id = {user_id}"
    return conn.execute(query)


def get_user_percent(conn, user_id):
    # planted: %-format SQL injection
    query = "SELECT * FROM users WHERE id = %s" % user_id
    return conn.execute(query)


def get_user_safe(conn, user_id):
    # NOT a smell: parameterized placeholder
    return conn.execute("SELECT * FROM users WHERE id = ?", (user_id,))
