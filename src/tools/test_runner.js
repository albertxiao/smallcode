// SmallCode — Test-Runner Auto-Discovery
//
// Detects the project's test runner from config files and provides a stable
// command to run tests after file edits. Small models waste 3-5 tool calls
// just figuring out HOW to run tests each session — this bakes it in once
// at workspace startup and re-injects it when relevant.
//
// Discovery priority per language ecosystem:
//
//   Node.js:    package.json scripts.test, then jest/vitest/mocha as devDeps
//   Python:     pytest.ini / pyproject.toml [tool.pytest] / setup.cfg [tool:pytest]
//               then plain `python -m pytest`, then unittest discovery
//   Rust:       Cargo.toml → `cargo test`
//   Go:         go.mod → `go test ./...`
//   Ruby:       Gemfile / .rspec → `bundle exec rspec` or `rake test`
//   Java/Gradle: build.gradle → `./gradlew test`
//   Java/Maven:  pom.xml → `mvn test`
//   C#/.NET:    *.sln / *.csproj → `dotnet test`
//
// Result is cached per session (re-scan on `invalidate()`).
//
// Configuration:
//   SMALLCODE_TEST_RUNNER=<cmd>   override detected command
//   SMALLCODE_TEST_DISABLE=true   turn off entirely

'use strict';

const fs = require('fs');
const path = require('path');

class TestRunnerDetector {
  constructor(options = {}) {
    this.workdir = options.workdir || process.cwd();
    this.disabled = options.disable || process.env.SMALLCODE_TEST_DISABLE === 'true';
    this.override = options.override || process.env.SMALLCODE_TEST_RUNNER || null;
    this._cache = null; // { command, framework, lang, confidence }
  }

  /**
   * Detect the test runner. Returns:
   *   { command, framework, lang, confidence }  on success
   *   null  if nothing found or disabled
   * Result is cached — call invalidate() to re-scan.
   */
  detect() {
    if (this.disabled) return null;
    if (this._cache !== null) return this._cache;
    if (this.override) {
      return (this._cache = { command: this.override, framework: 'custom', lang: 'custom', confidence: 1.0 });
    }
    const result = this._scan();
    this._cache = result;
    return result;
  }

  /** Clear the cache and force a re-scan next time detect() is called. */
  invalidate() { this._cache = null; }

  /**
   * Format a brief injection for the system prompt. Returns '' if nothing
   * found — keeps context clean for projects with no test infra.
   */
  formatForPrompt() {
    const r = this.detect();
    if (!r) return '';
    return `\n\nTest runner (${r.framework}): \`${r.command}\`  — run this after edits to verify changes.`;
  }

  // ─── Internal scan ───────────────────────────────────────────────────────

  _scan() {
    const cwd = this.workdir;
    const exists = (f) => { try { return fs.existsSync(path.join(cwd, f)); } catch { return false; } };
    const read = (f) => { try { return fs.readFileSync(path.join(cwd, f), 'utf-8'); } catch { return ''; } };

    // ── Node.js ──────────────────────────────────────────────────────────
    if (exists('package.json')) {
      try {
        const pkg = JSON.parse(read('package.json'));

        // Explicit test script — highest confidence
        const script = pkg.scripts && pkg.scripts.test;
        if (script && script !== 'echo "Error: no test specified" && exit 1' && script.trim() !== '') {
          // Detect vitest --run pattern (avoids watch mode)
          const cmd = this._nodeTestCmd(script, pkg);
          return { command: cmd, framework: _detectFramework(script), lang: 'javascript', confidence: 0.95 };
        }

        // Infer from devDependencies
        const dev = pkg.devDependencies || {};
        const dep = pkg.dependencies || {};
        if (dev.vitest || dep.vitest) return { command: 'npx vitest run', framework: 'vitest', lang: 'javascript', confidence: 0.8 };
        if (dev.jest || dep.jest) return { command: 'npx jest --passWithNoTests', framework: 'jest', lang: 'javascript', confidence: 0.8 };
        if (dev.mocha || dep.mocha) return { command: 'npx mocha', framework: 'mocha', lang: 'javascript', confidence: 0.75 };
        if (dev.tap || dep.tap) return { command: 'npx tap', framework: 'tap', lang: 'javascript', confidence: 0.7 };
        // Has test files but no explicit runner
        if (exists('test') || exists('tests') || exists('__tests__')) {
          return { command: 'node --test', framework: 'node-test', lang: 'javascript', confidence: 0.5 };
        }
      } catch {}
    }

    // ── Python ───────────────────────────────────────────────────────────
    {
      const hasPyproject = exists('pyproject.toml');
      const hasPytestIni = exists('pytest.ini') || exists('setup.cfg');
      const hasPyFiles = (() => { try { return fs.readdirSync(cwd).some(f => /^test_.*\.py$/.test(f) || /\.py$/.test(f)); } catch { return false; } })();
      const hasPyTests = exists('tests') || exists('test') || (() => { try { return fs.readdirSync(cwd).some(f => /^test_.*\.py$/.test(f)); } catch { return false; } })();
      // Only enter Python detection if there's actual Python evidence
      if (hasPyproject || hasPytestIni || hasPyFiles || exists('manage.py') || exists('requirements.txt') || exists('setup.py')) {
        if (hasPyproject) {
          const ppc = read('pyproject.toml');
          if (ppc.includes('[tool.pytest') || ppc.includes('[tool.pytest.ini_options]')) {
            return { command: 'python -m pytest', framework: 'pytest', lang: 'python', confidence: 0.95 };
          }
          if (ppc.includes('[tool.hatch') && ppc.includes('pytest')) {
            return { command: 'hatch test', framework: 'hatch+pytest', lang: 'python', confidence: 0.85 };
          }
        }
        if (hasPytestIni) return { command: 'python -m pytest', framework: 'pytest', lang: 'python', confidence: 0.9 };
        if (hasPyTests) return { command: 'python -m pytest', framework: 'pytest', lang: 'python', confidence: 0.7 };
        if (exists('manage.py')) return { command: 'python manage.py test', framework: 'django', lang: 'python', confidence: 0.8 };
        // Fallback to unittest
        if (exists('tests') || exists('test')) {
          return { command: 'python -m unittest discover', framework: 'unittest', lang: 'python', confidence: 0.5 };
        }
      }
    }

    // ── Rust ─────────────────────────────────────────────────────────────
    if (exists('Cargo.toml')) {
      return { command: 'cargo test', framework: 'cargo-test', lang: 'rust', confidence: 0.95 };
    }

    // ── Go ───────────────────────────────────────────────────────────────
    if (exists('go.mod')) {
      return { command: 'go test ./...', framework: 'go-test', lang: 'go', confidence: 0.95 };
    }

    // ── .NET / C# ────────────────────────────────────────────────────────
    {
      const slnFiles = this._glob(cwd, /\.sln$/);
      const csprojFiles = this._glob(cwd, /\.csproj$/);
      if (slnFiles.length > 0) {
        return { command: 'dotnet test', framework: 'dotnet', lang: 'csharp', confidence: 0.9 };
      }
      if (csprojFiles.length > 0) {
        return { command: 'dotnet test', framework: 'dotnet', lang: 'csharp', confidence: 0.85 };
      }
    }

    // ── Java/Gradle ──────────────────────────────────────────────────────
    if (exists('build.gradle') || exists('build.gradle.kts')) {
      const gradlew = exists('gradlew') ? './gradlew' : 'gradle';
      return { command: `${gradlew} test`, framework: 'gradle', lang: 'java', confidence: 0.9 };
    }

    // ── Java/Maven ───────────────────────────────────────────────────────
    if (exists('pom.xml')) {
      return { command: 'mvn test -q', framework: 'maven', lang: 'java', confidence: 0.9 };
    }

    // ── Ruby ─────────────────────────────────────────────────────────────
    if (exists('.rspec') || exists('spec')) {
      const useBundle = exists('Gemfile.lock');
      return { command: useBundle ? 'bundle exec rspec' : 'rspec', framework: 'rspec', lang: 'ruby', confidence: 0.85 };
    }
    if (exists('Rakefile')) {
      return { command: 'rake test', framework: 'rake', lang: 'ruby', confidence: 0.7 };
    }

    return null;
  }

  /** Adjust a node test script to run once (not in watch mode). */
  _nodeTestCmd(script, pkg) {
    // Vitest: add --run to prevent watch mode
    if (/\bvitest\b/.test(script) && !script.includes('--run')) {
      return (script + ' --run').replace(/\s+/, ' ');
    }
    // Jest: already single-run unless --watch is passed
    if (/\bjest\b/.test(script) && script.includes('--watch')) {
      return script.replace('--watch', '').replace('--watchAll', '').trim();
    }
    // Already fine — use as-is
    return script.startsWith('npm ') || script.startsWith('node ') ? script : `npm test`;
  }

  /** Shallow glob for files matching a regex in workdir. */
  _glob(dir, re) {
    try {
      if (!fs.existsSync(dir)) return [];
      return fs.readdirSync(dir).filter(f => re.test(f));
    } catch { return []; }
  }
}

function _detectFramework(script) {
  if (/vitest/.test(script)) return 'vitest';
  if (/jest/.test(script)) return 'jest';
  if (/mocha/.test(script)) return 'mocha';
  if (/tap/.test(script)) return 'tap';
  if (/ava/.test(script)) return 'ava';
  if (/jasmine/.test(script)) return 'jasmine';
  if (/playwright/.test(script)) return 'playwright';
  if (/cypress/.test(script)) return 'cypress';
  if (/pytest/.test(script)) return 'pytest';
  if (/node --test/.test(script)) return 'node-test';
  return 'npm-test';
}

// ─── Singleton ─────────────────────────────────────────────────────────────

let _instance = null;

function getTestRunnerDetector(options) {
  if (!_instance) _instance = new TestRunnerDetector(options || { workdir: process.cwd() });
  return _instance;
}

function resetTestRunnerDetector() { _instance = null; }

module.exports = {
  TestRunnerDetector,
  getTestRunnerDetector,
  resetTestRunnerDetector,
};
