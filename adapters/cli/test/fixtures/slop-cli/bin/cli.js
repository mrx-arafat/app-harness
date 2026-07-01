#!/usr/bin/env node
"use strict";

// Planted smells for the quality scanner:
//  1) a hardcoded absolute /Users/... path
//  2) a leftover debug console.log of a bare variable
const configPath = "/Users/example/secret/config.json";
const data = { path: configPath };
console.log(data);
