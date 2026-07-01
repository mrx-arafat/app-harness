import React from 'react';

// Clean component with neutral palette — no AI-slop patterns.
function App() {
  return (
    <main>
      <h1>My Application</h1>
      <p>Welcome. Navigate using the links below.</p>
      <nav>
        <a href="/">Home</a>
        <a href="/about">About</a>
        <a href="/contact">Contact</a>
      </nav>
      <section>
        <h2>Features</h2>
        <ul>
          <li>Fast and reliable</li>
          <li>Easy to use</li>
          <li>Well tested</li>
        </ul>
      </section>
    </main>
  );
}

export default App;
