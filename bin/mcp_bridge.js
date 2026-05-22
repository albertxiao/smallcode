// SmallCode — Code Graph MCP Bridge
// Manages the built-in budget-aware-mcp process for code intelligence

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const { createLineDemuxer } = require('../src/security/sanitize');

let mcpProcess = null;
let mcpDemuxer = null;
let mcpRequestId = 1;

function startCodeGraphMCP() {
  const possiblePaths = [
    path.join(__dirname, '..', '..', 'code-graph-mcp', 'dist', 'index.js'),
    path.join(__dirname, '..', 'node_modules', 'budget-aware-mcp', 'dist', 'index.js'),
    path.join(__dirname, '..', 'node_modules', '.package-lock.json'),
  ];

  let mcpPath = null;
  for (const p of possiblePaths) {
    if (fs.existsSync(p)) { mcpPath = p; break; }
  }

  if (!mcpPath) {
    const linkedPath = path.join(__dirname, '..', 'node_modules', 'budget-aware-mcp');
    if (fs.existsSync(linkedPath)) {
      const realPath = fs.realpathSync(linkedPath);
      const candidate = path.join(realPath, 'dist', 'index.js');
      if (fs.existsSync(candidate)) mcpPath = candidate;
    }
  }

  if (!mcpPath) {
    try {
      const { execSync } = require('child_process');
      const globalPath = execSync('npm root -g', { encoding: 'utf-8' }).trim();
      const gp = path.join(globalPath, 'budget-aware-mcp', 'dist', 'index.js');
      if (fs.existsSync(gp)) mcpPath = gp;
    } catch {}
  }

  if (!mcpPath) return null;

  const child = spawn('node', [mcpPath], {
    stdio: ['pipe', 'pipe', 'pipe'],
    cwd: process.cwd(),
    shell: false,
  });

  child.on('error', () => {});
  child.on('exit', () => {
    mcpProcess = null;
    if (mcpDemuxer) { try { mcpDemuxer.close(); } catch {} mcpDemuxer = null; }
  });

  mcpProcess = child;
  // Single shared line demuxer — replaces the per-request 'data' listener
  // pattern that leaked listeners and could resolve a request with another
  // request's response bytes under load.
  mcpDemuxer = createLineDemuxer(child.stdout);
  return child;
}

async function mcpCall(method, params = {}) {
  if (!mcpProcess) return null;

  return new Promise((resolve) => {
    if (!mcpProcess || !mcpProcess.stdout || !mcpProcess.stdin || !mcpDemuxer) { resolve(null); return; }

    const id = mcpRequestId++;
    const request = JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n';

    let timer = null;
    const finish = (val) => {
      if (timer) clearTimeout(timer);
      if (mcpDemuxer) mcpDemuxer.unregister(id);
      resolve(val);
    };

    mcpDemuxer.register(id, (line) => {
      try {
        const resp = JSON.parse(line);
        if (resp.id === id) finish(resp.result || null);
      } catch { /* keep listening */ }
    });

    try {
      mcpProcess.stdin.write(request);
    } catch {
      finish(null);
      return;
    }

    timer = setTimeout(() => finish(null), 5000);
  });
}

async function initCodeGraph(version) {
  const child = startCodeGraphMCP();
  if (!child) return false;

  // Use actual package version if not provided
  let resolvedVersion = version;
  if (!resolvedVersion) {
    try {
      const pkg = require('../package.json');
      resolvedVersion = pkg.version;
    } catch {}
    if (!resolvedVersion) resolvedVersion = '0.9.2';
  }

  const initResult = await mcpCall('initialize', {
    protocolVersion: '2024-11-05',
    capabilities: {},
    clientInfo: { name: 'smallcode', version: resolvedVersion },
  });

  if (!initResult) {
    mcpProcess = null;
    return false;
  }

  const listResult = await mcpCall('tools/call', { name: 'list_repos', arguments: {} });
  let alreadyIndexed = 0;
  if (listResult && listResult.content) {
    try {
      const data = JSON.parse(listResult.content[0]?.text || '{}');
      alreadyIndexed = data.total || 0;
    } catch {}
  }

  if (alreadyIndexed > 0) return true;

  const cwd = process.cwd();
  const subProjects = [];
  try {
    const entries = fs.readdirSync(cwd, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      if (entry.name.startsWith('.') || entry.name === 'node_modules' || entry.name === 'venv') continue;
      const subPath = path.join(cwd, entry.name);
      const markers = ['package.json', 'Cargo.toml', 'go.mod', 'pyproject.toml', 'src'];
      const hasMarker = markers.some(m => fs.existsSync(path.join(subPath, m)));
      if (hasMarker) subProjects.push({ path: subPath, name: entry.name });
    }
  } catch {}

  if (subProjects.length > 0) {
    for (const proj of subProjects.slice(0, 8)) {
      await mcpCall('tools/call', { name: 'index_repo', arguments: { path: proj.path, name: proj.name } });
    }
  } else {
    await mcpCall('tools/call', { name: 'index_repo', arguments: { path: cwd, name: path.basename(cwd) } });
  }

  return true;
}

function killMCP() {
  if (mcpDemuxer) { try { mcpDemuxer.close(); } catch {} mcpDemuxer = null; }
  if (mcpProcess) { mcpProcess.kill(); mcpProcess = null; }
}

function getMcpProcess() {
  return mcpProcess;
}

module.exports = { startCodeGraphMCP, mcpCall, initCodeGraph, killMCP, getMcpProcess };
