#!/usr/bin/env node
// Compiles src/compiled/*.ts → *.js via tsc
// No new dependencies — typescript is already a devDependency.
const { execSync } = require('child_process');
const path = require('path');
const root = __dirname;

console.log('[build] Compiling src/compiled TypeScript → JavaScript …');
execSync('npx tsc -p src/compiled/tsconfig.json', { cwd: root, stdio: 'inherit' });
console.log('[build] Done.');
