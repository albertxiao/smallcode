// SmallCode — Bootstrap Detection
//
// On first turn, scan the workspace for key config files and inject a
// 1-2 line project summary into the system prompt. Without this, small
// models waste 3-5 tool calls just to establish "this is a Node 18
// project with npm test, entry at src/index.js".
//
// What we detect (in priority order):
//   - Package manager + runtime (node/npm/yarn/pnpm, python/pip/poetry,
//     rust/cargo, go, dotnet, java/gradle/maven, ruby/bundler)
//   - Entry point / main file
//   - Scripts: test, build, start / dev
//   - Language version from .nvmrc / .python-version / .tool-versions
//   - Framework hints (express/fastapi/nextjs/react/vue/...)
//
// Output is a compact one-liner like:
//   "Node 20 (npm) — Next.js app. Build: `npm run build`. Test: `npm test`. Entry: src/app.js"
//
// Configuration:
//   SMALLCODE_BOOTSTRAP=false      disable entirely
//   SMALLCODE_BOOTSTRAP_MAX=200    max chars of the summary injected

'use strict';

const fs = require('fs');
const path = require('path');

const DEFAULT_MAX = parseInt(process.env.SMALLCODE_BOOTSTRAP_MAX) || 200;

class BootstrapDetector {
  constructor(options = {}) {
    this.workdir = options.workdir || process.cwd();
    this.disabled = options.disable || process.env.SMALLCODE_BOOTSTRAP === 'false';
    this.maxChars = options.maxChars || DEFAULT_MAX;
    this._cache = null;
  }

  /** Run detection and return { summary, parts } or null. Cached. */
  detect() {
    if (this.disabled) return null;
    if (this._cache !== null) return this._cache;
    this._cache = this._scan();
    return this._cache;
  }

  /** Format for system prompt injection. Returns '' if nothing found. */
  formatForPrompt() {
    const r = this.detect();
    if (!r) return '';
    const s = r.summary.length > this.maxChars
      ? r.summary.slice(0, this.maxChars - 1) + '…'
      : r.summary;
    // Label as "Project" — caller may relabel as "Workspace context" to avoid
    // models treating this as a complete project description.
    return `\n\nProject: ${s}`;
  }

  invalidate() { this._cache = null; }

  // ─── Internal ────────────────────────────────────────────────────────────

  _scan() {
    const cwd = this.workdir;
    const exists = f => { try { return fs.existsSync(path.join(cwd, f)); } catch { return false; } };
    const read = f => { try { return fs.readFileSync(path.join(cwd, f), 'utf-8'); } catch { return ''; } };
    const readJson = f => { try { return JSON.parse(read(f)); } catch { return null; } };

    const parts = {};

    // ── Node.js ──────────────────────────────────────────────────────────
    if (exists('package.json')) {
      const pkg = readJson('package.json');
      if (pkg) {
        // Runtime / version
        const nvmrc = read('.nvmrc').trim() || read('.node-version').trim();
        const toolVer = _parseToolVersions(read('.tool-versions'), 'nodejs') ||
                        _parseToolVersions(read('.tool-versions'), 'node');
        const nodeVer = nvmrc || toolVer || (pkg.engines && pkg.engines.node ? pkg.engines.node.replace(/[^0-9.]/g, '') : '');
        parts.runtime = `Node${nodeVer ? ' ' + nodeVer.split('.')[0] : ''}`;

        // Package manager
        if (exists('pnpm-lock.yaml')) parts.pm = 'pnpm';
        else if (exists('yarn.lock')) parts.pm = 'yarn';
        else parts.pm = 'npm';

        // Scripts
        const scripts = pkg.scripts || {};
        if (scripts.build) parts.build = `${parts.pm} run build`;
        if (scripts.test && !scripts.test.includes('no test specified')) parts.test = `${parts.pm} test`;
        if (scripts.start) parts.start = `${parts.pm} start`;
        else if (scripts.dev) parts.start = `${parts.pm} run dev`;

        // Entry / main — prefer bin entries (CLIs) over main (library entry)
        const bins = pkg.bin ? Object.values(pkg.bin) : [];
        if (bins.length > 0) parts.entry = bins[0];
        else if (pkg.main) parts.entry = pkg.main;

        // Framework hints from deps
        const allDeps = { ...pkg.dependencies, ...pkg.devDependencies };
        const fw = _nodeFramework(allDeps);
        if (fw) parts.framework = fw;
      }
    }
    // ── Python ───────────────────────────────────────────────────────────
    else if (exists('pyproject.toml') || exists('setup.py') || exists('setup.cfg') || exists('requirements.txt')) {
      const pyver = read('.python-version').trim() ||
                    _parseToolVersions(read('.tool-versions'), 'python') || '';
      parts.runtime = `Python${pyver ? ' ' + pyver.split('.').slice(0, 2).join('.') : ''}`;
      if (exists('poetry.lock')) parts.pm = 'poetry';
      else if (exists('Pipfile.lock')) parts.pm = 'pipenv';
      else parts.pm = 'pip';

      const ppc = read('pyproject.toml');
      const fw = _pythonFramework(ppc + read('requirements.txt'));
      if (fw) parts.framework = fw;

      if (exists('manage.py')) { parts.entry = 'manage.py'; parts.framework = parts.framework || 'django'; }
      else if (exists('app.py')) parts.entry = 'app.py';
      else if (exists('main.py')) parts.entry = 'main.py';
    }
    // ── Rust ─────────────────────────────────────────────────────────────
    else if (exists('Cargo.toml')) {
      parts.runtime = 'Rust';
      parts.build = 'cargo build';
      parts.test = 'cargo test';
      try {
        const cargo = read('Cargo.toml');
        const binMatch = cargo.match(/\[\[bin\]\]\s*\nname\s*=\s*"([^"]+)"/);
        if (binMatch) parts.entry = `src/${binMatch[1]}.rs`;
        else if (exists('src/main.rs')) parts.entry = 'src/main.rs';
        else if (exists('src/lib.rs')) parts.entry = 'src/lib.rs';
      } catch {}
    }
    // ── Go ───────────────────────────────────────────────────────────────
    else if (exists('go.mod')) {
      const gomod = read('go.mod');
      const goVer = (gomod.match(/^go\s+(\d+\.\d+)/m) || [])[1] || '';
      parts.runtime = `Go${goVer ? ' ' + goVer : ''}`;
      parts.build = 'go build ./...';
      parts.test = 'go test ./...';
      if (exists('main.go')) parts.entry = 'main.go';
      else if (exists('cmd')) parts.entry = 'cmd/';
    }
    // ── .NET ─────────────────────────────────────────────────────────────
    else if (exists('global.json') || this._glob(cwd, /\.sln$/).length > 0 || this._glob(cwd, /\.csproj$/).length > 0) {
      parts.runtime = '.NET';
      parts.build = 'dotnet build';
      parts.test = 'dotnet test';
    }
    // ── Java ─────────────────────────────────────────────────────────────
    else if (exists('pom.xml')) {
      parts.runtime = 'Java (Maven)';
      parts.build = 'mvn package -q';
      parts.test = 'mvn test -q';
    }
    else if (exists('build.gradle') || exists('build.gradle.kts')) {
      parts.runtime = 'Java (Gradle)';
      const gradlew = exists('gradlew') ? './gradlew' : 'gradle';
      parts.build = `${gradlew} build`;
      parts.test = `${gradlew} test`;
    }
    // ── Ruby ─────────────────────────────────────────────────────────────
    else if (exists('Gemfile')) {
      const rbver = read('.ruby-version').trim() ||
                    _parseToolVersions(read('.tool-versions'), 'ruby') || '';
      parts.runtime = `Ruby${rbver ? ' ' + rbver.split('.').slice(0, 2).join('.') : ''}`;
      parts.pm = 'bundler';
      if (exists('.rspec') || exists('spec')) parts.test = 'bundle exec rspec';
      else if (exists('Rakefile')) parts.test = 'rake test';
    }

    if (!parts.runtime) return null;

    // Assemble summary
    const summary = this._compose(parts);
    return { summary, parts };
  }

  _compose(p) {
    const segs = [];
    segs.push(`${p.runtime}${p.pm ? ` (${p.pm})` : ''}`);
    if (p.framework) segs.push(p.framework);
    if (p.entry) segs.push(`entry: ${p.entry}`);
    const cmds = [];
    if (p.build) cmds.push(`build: \`${p.build}\``);
    if (p.test) cmds.push(`test: \`${p.test}\``);
    if (p.start) cmds.push(`run: \`${p.start}\``);
    if (cmds.length) segs.push(cmds.join(', '));
    return segs.join(' — ');
  }

  _glob(dir, re) {
    try {
      if (!fs.existsSync(dir)) return [];
      return fs.readdirSync(dir).filter(f => re.test(f));
    } catch { return []; }
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function _parseToolVersions(content, tool) {
  if (!content) return '';
  const re = new RegExp(`^${tool}\\s+([\\d.]+)`, 'im');
  const m = content.match(re);
  return m ? m[1] : '';
}

function _nodeFramework(deps) {
  if (!deps) return '';
  if (deps.next) return 'Next.js';
  if (deps.nuxt) return 'Nuxt.js';
  if (deps['@angular/core']) return 'Angular';
  if (deps.react) return 'React';
  if (deps.vue) return 'Vue';
  if (deps.svelte) return 'Svelte';
  if (deps.express) return 'Express';
  if (deps.fastify) return 'Fastify';
  if (deps.koa) return 'Koa';
  if (deps.nestjs || deps['@nestjs/core']) return 'NestJS';
  if (deps.electron) return 'Electron';
  return '';
}

function _pythonFramework(content) {
  if (!content) return '';
  if (/fastapi/.test(content)) return 'FastAPI';
  if (/django/.test(content)) return 'Django';
  if (/flask/.test(content)) return 'Flask';
  if (/starlette/.test(content)) return 'Starlette';
  if (/aiohttp/.test(content)) return 'aiohttp';
  if (/tornado/.test(content)) return 'Tornado';
  return '';
}

// ─── Singleton ───────────────────────────────────────────────────────────────

let _instance = null;

function getBootstrapDetector(options) {
  if (!_instance) _instance = new BootstrapDetector(options || { workdir: process.cwd() });
  return _instance;
}

function resetBootstrapDetector() { _instance = null; }

module.exports = {
  BootstrapDetector,
  getBootstrapDetector,
  resetBootstrapDetector,
};
