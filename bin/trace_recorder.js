// SmallCode — Trace Recorder
// Records agent execution traces (tool calls, responses, validations)
// for replay, debugging, and test generation.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { redactValue, redactString } = require('../src/security/sanitize');

const FILE_MODE = 0o600;
const DIR_MODE = 0o700;

class TraceRecorder {
  constructor(workdir) {
    this.workdir = workdir || process.cwd();
    this.tracesDir = path.join(this.workdir, '.smallcode', 'traces');
    this.current = null; // Active trace
    this.recording = false;
  }

  /**
   * Start recording a new trace.
   */
  start(prompt, model) {
    this.current = {
      id: crypto.randomUUID().slice(0, 8),
      model,
      prompt,
      startedAt: new Date().toISOString(),
      steps: [],
      tokens: { prompt: 0, completion: 0 },
    };
    this.recording = true;
    return this.current.id;
  }

  /**
   * Record a tool call step.
   */
  recordToolCall(name, args, result, durationMs) {
    if (!this.recording || !this.current) return;
    // Redact args + result before persisting. Tool args from the model can
    // include literal API keys (e.g. when user pastes an env var into the
    // prompt) and tool results often contain file content with secrets.
    const safeArgs = redactValue(args);
    const safeResult = typeof result === 'string'
      ? redactString(result).slice(0, 2000)
      : JSON.stringify(redactValue(result)).slice(0, 2000);
    this.current.steps.push({
      type: 'tool_call',
      name,
      args: safeArgs,
      result: safeResult,
      durationMs,
      timestamp: Date.now(),
    });
  }

  /**
   * Record a model response (text or tool decision).
   */
  recordModelResponse(content, toolCalls) {
    if (!this.recording || !this.current) return;
    this.current.steps.push({
      type: 'model_response',
      content: content ? redactString(content).slice(0, 1000) : null,
      toolCalls: toolCalls ? toolCalls.map(tc => ({
        name: tc.function.name,
        args: typeof tc.function.arguments === 'string'
          ? redactString(tc.function.arguments)
          : JSON.stringify(redactValue(tc.function.arguments || {})),
      })) : null,
      timestamp: Date.now(),
    });
  }

  /**
   * Record token usage for this trace.
   */
  recordTokens(promptTokens, completionTokens) {
    if (!this.recording || !this.current) return;
    this.current.tokens.prompt += promptTokens || 0;
    this.current.tokens.completion += completionTokens || 0;
  }

  /**
   * Record a validation result.
   */
  recordValidation(filePath, passed, errors) {
    if (!this.recording || !this.current) return;
    this.current.steps.push({
      type: 'validation',
      filePath,
      passed,
      errors: errors ? errors.slice(0, 5) : [],
      timestamp: Date.now(),
    });
  }

  /**
   * Stop recording and save the trace.
   */
  stop() {
    if (!this.recording || !this.current) return null;
    this.current.endedAt = new Date().toISOString();
    this.current.durationMs = Date.now() - new Date(this.current.startedAt).getTime();
    // Redact prompt — it can contain pasted secrets, file paths, or
    // proprietary data the user wouldn't want shared via /share.
    this.current.prompt = redactString(this.current.prompt || '');
    this.recording = false;

    // Save to disk
    if (!fs.existsSync(this.tracesDir)) fs.mkdirSync(this.tracesDir, { recursive: true, mode: DIR_MODE });
    // Validate trace ID — defends against accidental injection via stop()
    // being called with a tampered current object.
    const id = String(this.current.id || '').replace(/[^A-Za-z0-9_-]/g, '');
    if (!id) { this.current = null; return null; }
    const filePath = path.join(this.tracesDir, `${id}.json`);
    if (!filePath.startsWith(this.tracesDir + path.sep)) { this.current = null; return null; }
    const tmpPath = filePath + `.tmp.${process.pid}.${Date.now()}`;
    fs.writeFileSync(tmpPath, JSON.stringify(this.current, null, 2), { mode: FILE_MODE });
    fs.renameSync(tmpPath, filePath);
    try { fs.chmodSync(filePath, FILE_MODE); } catch {}

    const saved = this.current;
    this.current = null;
    return saved;
  }

  /**
   * List all saved traces.
   */
  list() {
    if (!fs.existsSync(this.tracesDir)) return [];
    return fs.readdirSync(this.tracesDir)
      .filter(f => f.endsWith('.json'))
      .map(f => {
        try {
          const data = JSON.parse(fs.readFileSync(path.join(this.tracesDir, f), 'utf-8'));
          return {
            id: data.id,
            prompt: (data.prompt || '').slice(0, 60),
            model: data.model,
            steps: data.steps.length,
            tokens: data.tokens,
            startedAt: data.startedAt,
            durationMs: data.durationMs,
          };
        } catch { return null; }
      })
      .filter(Boolean)
      .sort((a, b) => new Date(b.startedAt) - new Date(a.startedAt));
  }

  /**
   * Load a trace by ID.
   */
  load(id) {
    if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(id)) return null;
    const filePath = path.join(this.tracesDir, `${id}.json`);
    if (!filePath.startsWith(this.tracesDir + path.sep)) return null;
    if (!fs.existsSync(filePath)) return null;
    return JSON.parse(fs.readFileSync(filePath, 'utf-8'));
  }

  /**
   * Generate a test file from a trace (trace-to-test).
   * Creates a Jest-compatible test that replays the tool calls.
   */
  generateTest(traceId) {
    const trace = this.load(traceId);
    if (!trace) return null;

    const toolSteps = trace.steps.filter(s => s.type === 'tool_call');
    if (toolSteps.length === 0) return null;

    const testLines = [
      `// Auto-generated from trace ${trace.id}`,
      `// Original prompt: "${trace.prompt.slice(0, 80).replace(/"/g, '\\"')}"`,
      `// Model: ${trace.model} | Steps: ${trace.steps.length} | Tokens: ${trace.tokens.prompt + trace.tokens.completion}`,
      ``,
      `const { execSync } = require('child_process');`,
      `const fs = require('fs');`,
      `const path = require('path');`,
      ``,
      `describe('Trace ${trace.id}: ${trace.prompt.slice(0, 40).replace(/'/g, "\\'")}', () => {`,
    ];

    for (let i = 0; i < toolSteps.length; i++) {
      const step = toolSteps[i];
      if (step.name === 'write_file' || step.name === 'patch') {
        const args = typeof step.args === 'string' ? JSON.parse(step.args) : step.args;
        testLines.push(`  test('step ${i + 1}: ${step.name} ${(args.path || '').slice(0, 30)}', () => {`);
        testLines.push(`    // Tool: ${step.name} took ${step.durationMs}ms`);
        if (step.name === 'write_file') {
          testLines.push(`    const filePath = path.resolve('${args.path}');`);
          testLines.push(`    // Verify file was created/exists after agent run`);
          testLines.push(`    expect(fs.existsSync(filePath)).toBe(true);`);
        }
        testLines.push(`  });`);
        testLines.push(``);
      } else if (step.name === 'bash') {
        const args = typeof step.args === 'string' ? JSON.parse(step.args) : step.args;
        const cmd = String(args.command || '');
        // Use JSON.stringify to escape the command for embedding in a JS
        // string literal — the prior `'${...}'` interpolation broke whenever
        // the command contained quotes, backticks, or backslashes, and could
        // produce invalid (or worse, injectable) test code.
        const cmdLiteral = JSON.stringify(cmd);
        testLines.push(`  test('step ${i + 1}: bash ${cmd.slice(0, 40).replace(/['`\\\r\n]/g, ' ')}', () => {`);
        testLines.push(`    // Verify command succeeds`);
        testLines.push(`    const result = execSync(${cmdLiteral}, { encoding: 'utf-8', timeout: 15000 });`);
        testLines.push(`    expect(result).toBeDefined();`);
        testLines.push(`  });`);
        testLines.push(``);
      }
    }

    testLines.push(`});`);
    return testLines.join('\n');
  }
}

module.exports = { TraceRecorder };
