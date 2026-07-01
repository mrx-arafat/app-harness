#!/usr/bin/env node
"use strict";

function help() {
  console.log("good-cli - a tiny example CLI");
  console.log("");
  console.log("Usage: good-cli [command] [options]");
  console.log("");
  console.log("Commands:");
  console.log("  greet <name>   Print a greeting");
  console.log("");
  console.log("Options:");
  console.log("  -h, --help     Show this help and exit");
}

function main(argv) {
  const args = argv.slice(2);
  if (args.length === 0 || args.indexOf("--help") !== -1 || args.indexOf("-h") !== -1) {
    help();
    return 0;
  }
  if (args[0] === "greet") {
    const name = args[1] || "world";
    console.log("Hello, " + name + "!");
    return 0;
  }
  console.error("error: unknown command: " + args[0]);
  return 1;
}

try {
  process.exit(main(process.argv));
} catch (err) {
  console.error("error: " + (err && err.message ? err.message : String(err)));
  process.exit(1);
}
