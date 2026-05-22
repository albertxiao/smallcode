// SmallCode — LSP Client (Lightweight)
// Connects to language servers for real diagnostics
// Supports TypeScript (tsserver), Python (pyright/pylsp), Rust (rust-analyzer)
//
// This replaces shelling out to `tsc --noEmit` or `python -m py_compile`
// with actual LSP diagnostics that understand the full project.

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

// LSP message framing
function encodeMessage(msg) {
  const content = JSON.stringify(msg);
  return `Content-Length: ${Buffer.byteLength(content)}\r\n\r\n${content}`;
}

function decodeMessages(buffer) {
  const messages = [];
  let remaining = buffer;

  while (remaining.length > 0) {
    const headerEnd = remaining.indexOf('\r\n\r\n');
    if (headerEnd === -1) break;

    const header = remaining.slice(0, headerEnd);
    const lengthMatch = header.match(/Content-Length: (\d+)/);
    if (!lengthMatch) break;

    const contentLength = parseInt(lengthMatch[1]);
    const contentStart = headerEnd + 4;

    if (remaining.length < contentStart + contentLength) break;

    const content = remaining.slice(contentStart, contentStart + contentLength);
    try {
      messages.push(JSON.parse(content));
    } catch {}

    remaining = remaining.slice(contentStart + contentLength);
  }

  return { messages, remaining };
}

// Detect which language server to use based on project files
function detectServer(cwd) {
  // TypeScript/JavaScript
  if (fs.existsSync(path.join(cwd, 'tsconfig.json')) || fs.existsSync(path.join(cwd, 'package.json'))) {
    return { cmd: 'typescript-language-server', args: ['--stdio'], language: 'typescript' };
  }
  // Python
  if (fs.existsSync(path.join(cwd, 'pyproject.toml')) || fs.existsSync(path.join(cwd, 'setup.py'))) {
    return { cmd: 'pyright-langserver', args: ['--stdio'], language: 'python' };
  }
  // Rust
  if (fs.existsSync(path.join(cwd, 'Cargo.toml'))) {
    return { cmd: 'rust-analyzer', args: [], language: 'rust' };
  }
  // Go
  if (fs.existsSync(path.join(cwd, 'go.mod'))) {
    return { cmd: 'gopls', args: ['serve'], language: 'go' };
  }
  return null;
}

class LSPClient {
  constructor(cwd) {
    this.cwd = cwd;
    this.process = null;
    this.requestId = 1;
    this.pending = new Map(); // id → { resolve, reject }
    this.diagnostics = new Map(); // uri → diagnostics[]
    this.buffer = '';
    this.initialized = false;
    this.serverInfo = null;
  }

  async start() {
    const server = detectServer(this.cwd);
    if (!server) return false;

    this.serverInfo = server;

    try {
      this.process = spawn(server.cmd, server.args, {
        cwd: this.cwd,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
    } catch {
      return false;
    }

    this.process.stdout.on('data', (data) => this._onData(data.toString()));
    this.process.stderr.on('data', () => {}); // Suppress stderr
    this.process.on('error', () => { this.process = null; });
    this.process.on('exit', () => { this.process = null; });

    // Initialize
    try {
      await this._request('initialize', {
        processId: process.pid,
        capabilities: { textDocument: { publishDiagnostics: {} } },
        rootUri: `file://${this.cwd.replace(/\\/g, '/')}`,
        workspaceFolders: [{ uri: `file://${this.cwd.replace(/\\/g, '/')}`, name: path.basename(this.cwd) }],
      });
      this._notify('initialized', {});
      this.initialized = true;
      return true;
    } catch {
      this.stop();
      return false;
    }
  }

  stop() {
    if (this.process) {
      try { this._request('shutdown', null); } catch {}
      this.process.kill();
      this.process = null;
    }
    this.initialized = false;
  }

  // Get diagnostics for a file
  async getDiagnostics(filePath) {
    const uri = `file://${path.resolve(this.cwd, filePath).replace(/\\/g, '/')}`;

    // Open the document to trigger diagnostics
    const content = fs.readFileSync(path.resolve(this.cwd, filePath), 'utf-8');
    this._notify('textDocument/didOpen', {
      textDocument: { uri, languageId: this.serverInfo?.language || 'plaintext', version: 1, text: content },
    });

    // Wait for diagnostics (published via notification)
    const diags = await new Promise((resolve) => {
      const timeout = setTimeout(() => resolve(this.diagnostics.get(uri) || []), 5000);
      const check = setInterval(() => {
        const diags = this.diagnostics.get(uri);
        if (diags && diags.length > 0) {
          clearInterval(check);
          clearTimeout(timeout);
          resolve(diags);
        }
      }, 200);
    });

    // Close the document after reading diagnostics to prevent the language
    // server from keeping it in memory indefinitely (Fix #20).
    this._notify('textDocument/didClose', { textDocument: { uri } });

    return diags;
  }

  // Format diagnostics as readable errors
  formatDiagnostics(diagnostics) {
    return diagnostics
      .filter(d => d.severity <= 2) // Error + Warning only
      .map(d => {
        const line = (d.range?.start?.line || 0) + 1;
        const severity = d.severity === 1 ? 'error' : 'warning';
        return `${severity} line ${line}: ${d.message}`;
      });
  }

  _request(method, params) {
    return new Promise((resolve, reject) => {
      const id = this.requestId++;
      this.pending.set(id, { resolve, reject });
      const msg = { jsonrpc: '2.0', id, method, params };
      this.process.stdin.write(encodeMessage(msg));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`LSP timeout: ${method}`));
        }
      }, 10000);
    });
  }

  _notify(method, params) {
    if (!this.process) return;
    const msg = { jsonrpc: '2.0', method, params };
    this.process.stdin.write(encodeMessage(msg));
  }

  _onData(data) {
    this.buffer += data;
    const { messages, remaining } = decodeMessages(this.buffer);
    this.buffer = remaining;

    for (const msg of messages) {
      // Response to a request
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(msg.error);
        else resolve(msg.result);
      }
      // Notification (diagnostics)
      if (msg.method === 'textDocument/publishDiagnostics') {
        this.diagnostics.set(msg.params.uri, msg.params.diagnostics || []);
      }
    }
  }
}

module.exports = { LSPClient, detectServer };
