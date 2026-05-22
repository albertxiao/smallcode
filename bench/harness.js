#!/usr/bin/env node
// SmallCode — Benchmark Harness
//
// Runs SmallCode against a curated set of small coding tasks, reports pass
// rate, mean time per task, and per-task breakdown. Stores results in
// .smallcode/benchmarks/<run-id>.json so progress is trackable over time.
//
// Suites:
//   - smoke         5 trivial tasks (sanity check, ~30s total)
//   - polyglot-mini 20 short Aider-Polyglot-style exercises across 5 langs
//   - tool-use      10 multi-step tasks that require tool sequencing
//
// Usage:
//   node bench/harness.js [--suite smoke] [--model NAME] [--timeout 180]
//   npm run bench
//
// Each task:
//   1. Creates a fresh temp workspace
//   2. Optionally writes seed files into it
//   3. Runs SmallCode non-interactively with the prompt
//   4. Runs a verification script (compile, test, exit code, file checks)
//   5. Records pass/fail + duration + tool call count

'use strict';

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');

const ROOT = path.resolve(__dirname, '..');
const SMALLCODE_BIN = path.join(ROOT, 'bin', 'smallcode.js');

// ─── Suites ────────────────────────────────────────────────────────────────

const SUITES = {
  smoke: [
    {
      id: 'create-hello',
      lang: 'python',
      prompt: 'Create hello.py with a function greet(name) that returns "Hello, {name}!" using an f-string.',
      verify: ({ dir }) => fs.existsSync(path.join(dir, 'hello.py')),
    },
    {
      id: 'fix-typo',
      lang: 'python',
      seed: { 'add.py': 'def add(a, b):\n    return a - b\n' },
      prompt: 'There is a bug in add.py — the function uses subtraction instead of addition. Fix it.',
      verify: ({ dir }) => {
        const content = fs.readFileSync(path.join(dir, 'add.py'), 'utf-8');
        return content.includes('a + b') && !content.includes('a - b');
      },
    },
    {
      id: 'create-readme',
      lang: 'markdown',
      prompt: 'Create a README.md describing a project called "TodoApp" with sections: ## Features, ## Install, ## Usage.',
      verify: ({ dir }) => {
        const p = path.join(dir, 'README.md');
        if (!fs.existsSync(p)) return false;
        const c = fs.readFileSync(p, 'utf-8');
        return c.includes('## Features') && c.includes('## Install') && c.includes('## Usage');
      },
    },
    {
      id: 'multi-file',
      lang: 'python',
      prompt: 'Create two files: utils.py with a function double(x) returning x*2, and main.py that imports double from utils and prints double(5).',
      verify: ({ dir }) => {
        const utils = path.join(dir, 'utils.py');
        const main = path.join(dir, 'main.py');
        if (!fs.existsSync(utils) || !fs.existsSync(main)) return false;
        return fs.readFileSync(utils, 'utf-8').includes('def double') &&
               fs.readFileSync(main, 'utf-8').includes('from utils');
      },
    },
    {
      id: 'shell-command',
      lang: 'shell',
      prompt: 'Use bash to create a file called "marker.txt" with the text "found".',
      verify: ({ dir }) => {
        const p = path.join(dir, 'marker.txt');
        return fs.existsSync(p) && fs.readFileSync(p, 'utf-8').includes('found');
      },
    },
  ],

  // Polyglot-mini: 4 tasks per language, intentionally short and self-contained.
  // Each task has a deterministic verify step that does NOT require running tests
  // (to keep the harness fast and not dependent on language toolchains).
  'polyglot-mini': [
    // Python (4)
    {
      id: 'py-fibonacci',
      lang: 'python',
      prompt: 'Create fib.py with a function fib(n) returning the nth Fibonacci number (fib(0)=0, fib(1)=1).',
      verify: ({ dir }) => {
        const p = path.join(dir, 'fib.py');
        if (!fs.existsSync(p)) return false;
        const c = fs.readFileSync(p, 'utf-8');
        return /def fib/.test(c);
      },
    },
    {
      id: 'py-class-account',
      lang: 'python',
      prompt: 'Create account.py with a class Account that has methods deposit(amount), withdraw(amount), and balance().',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'account.py'), 'utf-8');
        return /class Account/.test(c) && /def deposit/.test(c) && /def withdraw/.test(c) && /def balance/.test(c);
      },
    },
    {
      id: 'py-fix-list',
      lang: 'python',
      seed: { 'sum.py': 'def sum_list(items):\n    total = 0\n    for x in items:\n        total += 2 * x\n    return total\n' },
      prompt: 'Fix sum_list in sum.py — it should sum the items, not double them.',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'sum.py'), 'utf-8');
        return c.includes('total += x') || c.includes('sum(items)') || c.includes('total = total + x');
      },
    },
    {
      id: 'py-add-test',
      lang: 'python',
      seed: { 'mul.py': 'def mul(a, b):\n    return a * b\n' },
      prompt: 'Add a test_mul.py file with three unittest test cases for the mul function in mul.py.',
      verify: ({ dir }) => {
        const p = path.join(dir, 'test_mul.py');
        if (!fs.existsSync(p)) return false;
        const c = fs.readFileSync(p, 'utf-8');
        return /unittest/.test(c) && (c.match(/def test/g) || []).length >= 3;
      },
    },

    // JavaScript (4)
    {
      id: 'js-double',
      lang: 'javascript',
      prompt: 'Create double.js exporting a function double(x) that returns x*2. Use module.exports.',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'double.js'), 'utf-8');
        return /module\.exports/.test(c) && /double/.test(c);
      },
    },
    {
      id: 'js-arrow',
      lang: 'javascript',
      seed: { 'app.js': 'function add(a, b) {\n    return a + b;\n}\n\nmodule.exports = { add };\n' },
      prompt: 'Refactor add in app.js to use arrow function syntax, keeping the same module.exports.',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'app.js'), 'utf-8');
        return /=>\s*\{?\s*(?:return\s+)?a\s*\+\s*b/.test(c) || /=\s*\(?a,\s*b\)?\s*=>/.test(c);
      },
    },
    {
      id: 'js-package',
      lang: 'javascript',
      prompt: 'Create a package.json for a Node.js project named "calc" with version 1.0.0, main "index.js", and one dev dependency "jest" set to ^29.0.0.',
      verify: ({ dir }) => {
        const p = path.join(dir, 'package.json');
        if (!fs.existsSync(p)) return false;
        try {
          const j = JSON.parse(fs.readFileSync(p, 'utf-8'));
          return j.name === 'calc' && j.devDependencies?.jest;
        } catch { return false; }
      },
    },
    {
      id: 'js-fix-async',
      lang: 'javascript',
      seed: { 'fetcher.js': 'function getData() {\n    fetch("/api").then(r => r.json());\n}\nmodule.exports = { getData };\n' },
      prompt: 'Make getData in fetcher.js an async function that returns the JSON.',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'fetcher.js'), 'utf-8');
        return /async\s+function\s+getData/.test(c) && /await/.test(c) && /return/.test(c);
      },
    },

    // TypeScript (3)
    {
      id: 'ts-interface',
      lang: 'typescript',
      prompt: 'Create types.ts with an interface User { id: number; name: string; email: string; } and export it.',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'types.ts'), 'utf-8');
        return /interface User/.test(c) && /id:\s*number/.test(c) && /name:\s*string/.test(c);
      },
    },
    {
      id: 'ts-generic',
      lang: 'typescript',
      prompt: 'Create stack.ts exporting a generic class Stack<T> with push(item: T), pop(): T | undefined, and size(): number.',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'stack.ts'), 'utf-8');
        return /class Stack<T>/.test(c) && /push/.test(c) && /pop/.test(c) && /size/.test(c);
      },
    },
    {
      id: 'ts-tsconfig',
      lang: 'typescript',
      prompt: 'Create a tsconfig.json with strict mode enabled, target ES2022, module CommonJS, outDir dist.',
      verify: ({ dir }) => {
        try {
          const j = JSON.parse(fs.readFileSync(path.join(dir, 'tsconfig.json'), 'utf-8'));
          return j.compilerOptions?.strict === true && /ES2022/i.test(j.compilerOptions?.target || '');
        } catch { return false; }
      },
    },

    // Bash/shell (3)
    {
      id: 'sh-list',
      lang: 'shell',
      seed: { 'a.txt': '', 'b.txt': '', 'c.txt': '' },
      prompt: 'Use bash to list all .txt files in the current directory and save the output to files.txt.',
      verify: ({ dir }) => {
        const p = path.join(dir, 'files.txt');
        if (!fs.existsSync(p)) return false;
        const c = fs.readFileSync(p, 'utf-8');
        return c.includes('a.txt') && c.includes('b.txt') && c.includes('c.txt');
      },
    },
    {
      id: 'sh-makefile',
      lang: 'shell',
      prompt: 'Create a Makefile with three targets: build (echoes "building"), test (echoes "testing"), and clean (echoes "cleaning"). Each must be tab-indented.',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'Makefile'), 'utf-8');
        return /build:/.test(c) && /test:/.test(c) && /clean:/.test(c) && c.includes('\t');
      },
    },
    {
      id: 'sh-script',
      lang: 'shell',
      prompt: 'Create a run.sh shell script that prints "starting", then prints the current directory, then prints "done". First line should be #!/bin/sh shebang.',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'run.sh'), 'utf-8');
        return /^#!/.test(c) && /starting/.test(c) && /done/.test(c) && /pwd|cd/.test(c);
      },
    },

    // Markdown/docs (2)
    {
      id: 'md-readme',
      lang: 'markdown',
      prompt: 'Create README.md with a project description, install instructions (npm install), usage example with a fenced code block, and a license section (MIT).',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'README.md'), 'utf-8');
        return /npm install/.test(c) && /```/.test(c) && /MIT/i.test(c);
      },
    },
    {
      id: 'md-api',
      lang: 'markdown',
      prompt: 'Create API.md documenting two endpoints: GET /users (returns list of users) and POST /users (creates user). Include request/response examples for each.',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'API.md'), 'utf-8');
        return /GET\s+\/users/.test(c) && /POST\s+\/users/.test(c);
      },
    },

    // JSON (2)
    {
      id: 'json-config',
      lang: 'json',
      prompt: 'Create config.json with: name "myapp", version "1.0.0", port 3000, features as an array containing "auth" and "logging".',
      verify: ({ dir }) => {
        try {
          const j = JSON.parse(fs.readFileSync(path.join(dir, 'config.json'), 'utf-8'));
          return j.name === 'myapp' && j.port === 3000 &&
                 Array.isArray(j.features) && j.features.includes('auth') && j.features.includes('logging');
        } catch { return false; }
      },
    },
    {
      id: 'json-fix',
      lang: 'json',
      seed: { 'broken.json': '{\n  "name": "test"\n  "version": "1.0",\n}' },
      prompt: 'Fix the JSON syntax errors in broken.json.',
      verify: ({ dir }) => {
        try { JSON.parse(fs.readFileSync(path.join(dir, 'broken.json'), 'utf-8')); return true; }
        catch { return false; }
      },
    },

    // Multi-file (2)
    {
      id: 'multi-imports',
      lang: 'python',
      prompt: 'Create math_utils/__init__.py and math_utils/operations.py. operations.py should have add(a,b) and multiply(a,b). __init__.py should re-export both.',
      verify: ({ dir }) => {
        const init = path.join(dir, 'math_utils', '__init__.py');
        const ops = path.join(dir, 'math_utils', 'operations.py');
        if (!fs.existsSync(init) || !fs.existsSync(ops)) return false;
        const opsC = fs.readFileSync(ops, 'utf-8');
        return /def add/.test(opsC) && /def multiply/.test(opsC);
      },
    },
  ],

  'tool-use': [
    {
      id: 'cd-and-create',
      lang: 'shell',
      prompt: 'Create a subdirectory called "src", cd into it, then create a file "main.py" with print("hello"). Use the bash tool. Verify by running ls/dir afterward.',
      verify: ({ dir }) => {
        const p = path.join(dir, 'src', 'main.py');
        return fs.existsSync(p) && fs.readFileSync(p, 'utf-8').includes('hello');
      },
    },
    {
      id: 'env-var',
      lang: 'shell',
      prompt: 'Use bash to set an env var FOO to "bar" in one tool call, then in a SECOND separate tool call write the value of FOO to env.txt.',
      verify: ({ dir }) => {
        const p = path.join(dir, 'env.txt');
        return fs.existsSync(p) && fs.readFileSync(p, 'utf-8').trim().includes('bar');
      },
    },
    {
      id: 'search-and-edit',
      lang: 'python',
      seed: {
        'a.py': 'def foo():\n    return "old"\n',
        'b.py': 'from a import foo\nprint(foo())\n',
      },
      prompt: 'Find every occurrence of the string "old" in the project and change it to "new".',
      verify: ({ dir }) => {
        const a = fs.readFileSync(path.join(dir, 'a.py'), 'utf-8');
        return a.includes('"new"') && !a.includes('"old"');
      },
    },
    {
      id: 'create-and-validate',
      lang: 'python',
      prompt: 'Create valid_json.json with {"name":"test","items":[1,2,3]}. Then verify it parses correctly using a bash command (python -c).',
      verify: ({ dir }) => {
        try {
          const j = JSON.parse(fs.readFileSync(path.join(dir, 'valid_json.json'), 'utf-8'));
          return j.name === 'test' && Array.isArray(j.items);
        } catch { return false; }
      },
    },
    {
      id: 'rename-symbol',
      lang: 'javascript',
      seed: {
        'lib.js': 'function getUserName(u) { return u.name; }\nmodule.exports = { getUserName };\n',
        'app.js': 'const { getUserName } = require("./lib");\nconsole.log(getUserName({name: "alice"}));\n',
      },
      prompt: 'Rename getUserName to fetchUsername everywhere in the project (both lib.js and app.js).',
      verify: ({ dir }) => {
        const lib = fs.readFileSync(path.join(dir, 'lib.js'), 'utf-8');
        const app = fs.readFileSync(path.join(dir, 'app.js'), 'utf-8');
        return lib.includes('fetchUsername') && !lib.includes('getUserName') &&
               app.includes('fetchUsername') && !app.includes('getUserName');
      },
    },
    {
      id: 'add-feature-multi',
      lang: 'python',
      seed: {
        'calc.py': 'def add(a,b): return a+b\ndef sub(a,b): return a-b\n',
        'test_calc.py': 'from calc import add, sub\nassert add(2,3)==5\nassert sub(5,2)==3\n',
      },
      prompt: 'Add a multiply function to calc.py and a corresponding assertion to test_calc.py for multiply(3,4)==12.',
      verify: ({ dir }) => {
        const calc = fs.readFileSync(path.join(dir, 'calc.py'), 'utf-8');
        const test = fs.readFileSync(path.join(dir, 'test_calc.py'), 'utf-8');
        return /def multiply/.test(calc) && /multiply\(3\s*,\s*4\)/.test(test);
      },
    },
    {
      id: 'fix-from-error',
      lang: 'python',
      seed: { 'broken.py': 'def divide(a, b):\n    return a / b\n\nprint(divide(10, 0))\n' },
      prompt: 'Run broken.py and fix whatever error occurs. Add proper handling for division by zero — return None on b==0.',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'broken.py'), 'utf-8');
        return /b\s*==\s*0/.test(c) && /return\s+None/.test(c);
      },
    },
    {
      id: 'config-update',
      lang: 'json',
      seed: { 'package.json': '{"name":"app","version":"1.0.0","scripts":{"start":"node index.js"}}' },
      prompt: 'Add a "test" script to package.json that runs "jest", and add jest ^29.0.0 to devDependencies.',
      verify: ({ dir }) => {
        try {
          const j = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf-8'));
          return j.scripts?.test === 'jest' && !!j.devDependencies?.jest;
        } catch { return false; }
      },
    },
    {
      id: 'count-lines',
      lang: 'shell',
      seed: { 'data.txt': 'line1\nline2\nline3\nline4\nline5\n' },
      prompt: 'Count the lines in data.txt and write the count (just the number) to count.txt.',
      verify: ({ dir }) => {
        const c = fs.readFileSync(path.join(dir, 'count.txt'), 'utf-8').trim();
        return c === '5';
      },
    },
    {
      id: 'init-project',
      lang: 'multi',
      prompt: 'Initialize a small project with these files: README.md (just a title), src/index.js (console.log "ready"), .gitignore (ignore node_modules), package.json (name "demo" version 0.1.0).',
      verify: ({ dir }) => {
        const r = fs.existsSync(path.join(dir, 'README.md'));
        const i = fs.existsSync(path.join(dir, 'src', 'index.js'));
        const g = fs.existsSync(path.join(dir, '.gitignore'));
        const p = fs.existsSync(path.join(dir, 'package.json'));
        if (!r || !i || !g || !p) return false;
        try {
          const pkg = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf-8'));
          return pkg.name === 'demo';
        } catch { return false; }
      },
    },
  ],
};

// ─── Runner ────────────────────────────────────────────────────────────────

// Load .env from the SmallCode project root so env vars are available
// when we spawn child processes in temp working dirs (which don't have .env).
function loadDotenv(filePath) {
  const env = {};
  try {
    const content = fs.readFileSync(filePath, 'utf-8');
    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eqIdx = trimmed.indexOf('=');
      if (eqIdx === -1) continue;
      const key = trimmed.slice(0, eqIdx).trim();
      let value = trimmed.slice(eqIdx + 1).trim();
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
      }
      env[key] = value;
    }
  } catch {}
  return env;
}

const ROOT_ENV = loadDotenv(path.join(ROOT, '.env'));

function parseArgs(argv) {
  const args = { suite: 'smoke', timeout: 240, model: null, baseUrl: null };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--suite') args.suite = argv[++i];
    else if (a === '--timeout') args.timeout = parseInt(argv[++i], 10);
    else if (a === '--model') args.model = argv[++i];
    else if (a === '--base-url') args.baseUrl = argv[++i];
    else if (a === '--list') args.list = true;
    else if (a === '--task') args.task = argv[++i];
  }
  return args;
}

function runOne(task, opts) {
  return new Promise((resolve) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), `bench-${task.id}-`));
    if (task.seed) {
      for (const [name, content] of Object.entries(task.seed)) {
        const p = path.join(tmpDir, name);
        fs.mkdirSync(path.dirname(p), { recursive: true });
        fs.writeFileSync(p, content);
      }
    }

    // Order: ROOT_ENV first so .env values are baseline, then process.env wins
    // for explicit overrides (--model flag etc).
    const env = { ...ROOT_ENV, ...process.env, SMALLCODE_AUTO_APPROVE: 'true' };
    if (opts.model) env.SMALLCODE_MODEL = opts.model;
    if (opts.baseUrl) env.SMALLCODE_BASE_URL = opts.baseUrl;
    if (!env.SMALLCODE_PROVIDER) env.SMALLCODE_PROVIDER = 'openai';
    // Ensure NO_COLOR so the tool-call counter on stdout is reliable
    // (without this, ANSI sequences like \u001b[2m⚙ break our regex).
    env.NO_COLOR = '1';
    env.FORCE_COLOR = '0';

    const startMs = Date.now();
    const child = spawn(
      'node',
      [SMALLCODE_BIN, '--non-interactive', '-P', task.prompt],
      {
        cwd: tmpDir,
        env,
        stdio: ['ignore', 'pipe', 'pipe'],
        // detached on POSIX so we can kill the whole process group on timeout.
        // (process.kill(-pid, 'SIGKILL') — without detached, child's children
        // survive the kill and keep the harness hanging.)
        detached: process.platform !== 'win32',
      }
    );

    let output = '';
    let toolCalls = 0;
    // Strip ANSI before counting — even with NO_COLOR some libs ignore it
    const ansiRe = /\u001b\[[0-9;]*[a-zA-Z]/g;
    child.stdout.on('data', (d) => {
      const s = d.toString();
      output += s;
      const clean = s.replace(ansiRe, '');
      const m = clean.match(/⚙ /g);
      if (m) toolCalls += m.length;
    });
    child.stderr.on('data', (d) => { output += d.toString(); });

    let killed = false;
    const killTimer = setTimeout(() => {
      killed = true;
      try {
        if (process.platform === 'win32') {
          // taskkill the whole tree on Windows
          require('child_process').exec(`taskkill /pid ${child.pid} /T /F`).on('error', () => {});
        } else {
          // Negative PID = whole process group (detached: true above made this possible)
          try { process.kill(-child.pid, 'SIGKILL'); } catch { try { child.kill('SIGKILL'); } catch {} }
        }
      } catch {}
    }, (opts.timeout || 180) * 1000);

    child.on('exit', (code) => {
      clearTimeout(killTimer);
      const elapsedMs = Date.now() - startMs;
      let passed = false;
      let verifyError = null;
      try {
        passed = !!task.verify({ dir: tmpDir, output, exitCode: code });
      } catch (e) {
        verifyError = e.message;
      }
      try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch {}
      resolve({
        id: task.id,
        lang: task.lang,
        passed,
        elapsedMs,
        exitCode: code,
        toolCalls,
        verifyError: verifyError || (killed ? 'timeout — killed' : null),
        timedOut: killed,
      });
    });
  });
}

async function main() {
  const args = parseArgs(process.argv);

  if (args.list) {
    console.log('Available suites:');
    for (const name of Object.keys(SUITES)) {
      console.log(`  ${name.padEnd(16)} ${SUITES[name].length} tasks`);
    }
    process.exit(0);
  }

  const suite = SUITES[args.suite];
  if (!suite) {
    console.error(`Unknown suite: ${args.suite}. Available: ${Object.keys(SUITES).join(', ')}`);
    process.exit(2);
  }

  const tasks = args.task ? suite.filter(t => t.id === args.task) : suite;
  if (tasks.length === 0) {
    console.error(`No tasks matched.`);
    process.exit(2);
  }

  const runId = new Date().toISOString().replace(/[:.]/g, '-') + '-' + crypto.randomBytes(2).toString('hex');
  console.log(`SmallCode Benchmark — suite: ${args.suite}, tasks: ${tasks.length}, run: ${runId}`);
  console.log(`Model: ${args.model || process.env.SMALLCODE_MODEL || '(from .env)'}`);
  console.log('');

  const results = [];
  for (let i = 0; i < tasks.length; i++) {
    const t = tasks[i];
    process.stdout.write(`[${i+1}/${tasks.length}] ${t.id.padEnd(28)} ... `);
    const r = await runOne(t, args);
    results.push(r);
    const mark = r.passed ? '✅' : '❌';
    const dur = (r.elapsedMs / 1000).toFixed(1) + 's';
    const calls = `${r.toolCalls}t`;
    console.log(`${mark} ${dur.padStart(6)} ${calls.padStart(5)}${r.verifyError ? ` (verify err: ${r.verifyError})` : ''}`);
  }

  const passed = results.filter(r => r.passed).length;
  const total = results.length;
  const totalMs = results.reduce((s, r) => s + r.elapsedMs, 0);
  const meanMs = totalMs / total;

  console.log('');
  console.log(`──── Summary ────`);
  console.log(`Pass rate    : ${passed}/${total} (${Math.round(passed/total*100)}%)`);
  console.log(`Total time   : ${(totalMs/1000).toFixed(1)}s`);
  console.log(`Mean per task: ${(meanMs/1000).toFixed(1)}s`);

  // Per-language breakdown
  const byLang = {};
  for (const r of results) {
    if (!byLang[r.lang]) byLang[r.lang] = { passed: 0, total: 0 };
    byLang[r.lang].total++;
    if (r.passed) byLang[r.lang].passed++;
  }
  console.log('');
  console.log('Per language:');
  for (const [lang, stats] of Object.entries(byLang)) {
    console.log(`  ${lang.padEnd(12)} ${stats.passed}/${stats.total}`);
  }

  // Persist result
  const benchDir = path.join(process.cwd(), '.smallcode', 'benchmarks');
  fs.mkdirSync(benchDir, { recursive: true });
  const outPath = path.join(benchDir, `${runId}.json`);
  fs.writeFileSync(outPath, JSON.stringify({
    runId,
    suite: args.suite,
    model: args.model || process.env.SMALLCODE_MODEL,
    baseUrl: args.baseUrl || process.env.SMALLCODE_BASE_URL,
    startedAt: new Date().toISOString(),
    summary: { passed, total, totalMs, meanMs, byLang },
    results,
  }, null, 2));
  console.log('');
  console.log(`Saved: ${outPath}`);

  process.exit(passed === total ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(2); });
