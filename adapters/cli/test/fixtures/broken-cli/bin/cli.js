#!/usr/bin/env node
"use strict";

// Intentional syntax error: an assignment with no right-hand side.
// `node --check` (the cli gate's build step) must reject this file.
const broken = ;

console.log("this line never parses", broken);
