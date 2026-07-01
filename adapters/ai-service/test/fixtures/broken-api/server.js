"use strict";
// Intentionally BROKEN fixture: throws during startup before binding a port, so
// the gate boot check fails (process exits non-zero, port never opens).
throw new Error("startup crash: required config MISSING_ENV is not set");
