"use strict";
// Intentionally failing test with a distinctive, greppable message so test.sh
// can assert the gate's `test` check `detail` actually captured it (regression
// guard for the LAST_OUT-in-a-subshell bug that used to make `detail` empty).
console.error("AssertionError: expected 2 to equal 3");
process.exit(1);
