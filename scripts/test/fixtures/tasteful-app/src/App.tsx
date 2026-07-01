import React from 'react';

// Tasteful design with cream background and Fraunces display heading.
// Triggers the tasteful-default project-level signal (cream+serif).
function App() {
  return (
    <div style={{ background: '#faf8f5', padding: '3rem' }}>
      <h1 style={{ fontFamily: 'Fraunces, Georgia, serif', fontSize: '2.5rem', color: '#1a1a1a' }}>
        Welcome
      </h1>
      <p style={{ color: '#444444', lineHeight: 1.7, maxWidth: '600px' }}>
        A calm, readable experience designed with care.
      </p>
      <nav style={{ marginTop: '2rem' }}>
        <a href="/" style={{ color: '#444444', textDecoration: 'none' }}>Home</a>
      </nav>
    </div>
  );
}

export default App;
