// SmallCode — ACP (Agent Context Protocol) Adapter
// Exposes SmallCode as an ACP-compatible agent for Zed IDE integration
// See: https://zed.dev/acp
//
// This adapter translates between ACP's protocol and SmallCode's internal tool system.
// Start with: smallcode --acp
//
// ACP protocol basics:
// - Agent receives context (files, selections, diagnostics) from the IDE
// - Agent responds with actions (edits, commands, messages)
// - Communication over stdio (JSON-RPC similar to MCP/LSP)

const readline = require('readline');

class ACPAdapter {
  constructor(agentLoop, config) {
    this.agentLoop = agentLoop;
    this.config = config;
    this.capabilities = {
      edit: true,
      command: true,
      chat: true,
      diagnostics: true,
    };
  }

  start() {
    const rl = readline.createInterface({ input: process.stdin });

    // Send initialization
    this._send({
      type: 'agent.capabilities',
      capabilities: this.capabilities,
      name: 'SmallCode',
      version: require('../../package.json').version,
    });

    rl.on('line', async (line) => {
      try {
        const msg = JSON.parse(line);
        await this._handleMessage(msg);
      } catch (e) {
        this._send({ type: 'error', message: e.message });
      }
    });

    rl.on('close', () => process.exit(0));
  }

  async _handleMessage(msg) {
    switch (msg.type) {
      case 'context.update':
        // IDE sends file context, selections, diagnostics
        // Store for use in the next prompt
        this._context = msg;
        break;

      case 'prompt':
        // User sends a message through the IDE
        const response = await this._runPrompt(msg.text, msg.context);
        this._send({ type: 'response', id: msg.id, ...response });
        break;

      case 'action.confirm':
        // User approved/rejected a proposed action
        break;

      case 'shutdown':
        process.exit(0);
        break;

      default:
        this._send({ type: 'error', message: `Unknown message type: ${msg.type}` });
    }
  }

  async _runPrompt(text, context) {
    // Build augmented prompt with IDE context
    let augmented = text;

    if (context?.file) {
      augmented += `\n\nCurrent file: ${context.file.path}`;
      if (context.file.selection) {
        augmented += `\nSelected text (lines ${context.file.selection.start}-${context.file.selection.end}):\n${context.file.selection.text}`;
      }
    }

    if (context?.diagnostics?.length > 0) {
      augmented += '\n\nIDE diagnostics:\n' + context.diagnostics.map(d => 
        `  ${d.severity} ${d.file}:${d.line}: ${d.message}`
      ).join('\n');
    }

    // Run through SmallCode's agent loop
    // This is a simplified version — full integration would maintain conversation state
    const result = { actions: [], message: '' };

    try {
      // Delegate to the agent loop and capture results
      // In full integration, this would use the same runAgentLoop
      result.message = `Processed: ${text.slice(0, 100)}`;
    } catch (e) {
      result.message = `Error: ${e.message}`;
    }

    return result;
  }

  _send(msg) {
    process.stdout.write(JSON.stringify(msg) + '\n');
  }
}

module.exports = { ACPAdapter };
