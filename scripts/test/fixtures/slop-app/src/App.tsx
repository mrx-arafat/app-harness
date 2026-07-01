import React from 'react';

// This component intentionally contains AI-slop tells for testing purposes.
// DO NOT use as a real component.

function HeroSection() {
  // TODO: Remove placeholder content before launch
  console.log('debug render');

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-r from-purple-500 to-indigo-600">
      <div className="text-center">
        <h1 className="bg-clip-text text-transparent bg-gradient-to-r from-pink-500 to-yellow-500 text-6xl font-bold">
          Your Amazing App
        </h1>
        <p className="mt-4 text-white">
          Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod
        </p>
        <p className="mt-2 text-white">
          Contact us: john@example.com
        </p>
        <button className="mt-8 px-6 py-3 bg-white text-purple-600 rounded-full">
          Get Started
        </button>
      </div>
      {/* from-purple-500 to-indigo-600 bg-clip-text text-transparent unslop-ignore */}
    </div>
  );
}

export default HeroSection;
