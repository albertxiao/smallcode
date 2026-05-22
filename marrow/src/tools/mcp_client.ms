// SmallCode - MCP Client
// Connects TO external MCP servers to consume their tools
// Lets SmallCode use GitHub, databases, documentation servers, etc.

import { exec } from "std/process"
import { readFile, pathExists } from "std/fs"
import { cwd, homedir } from "std/env"
import { ToolRegistry, ToolDef, ToolParam, ToolResult, ToolContext } from "./registry"
import { EventBus } from "../core/event_bus"

pub struct MCPServerConfig {
  name: String
  command: String
  args: List<String>
  env: Map<String, String>
  disabled: Bool
  autoApprove: List<String>
}

pub struct MCPClientTool {
  serverName: String
  name: String
  description: String
  inputSchema: Map<String, Any>
}

pub struct MCPClient {
  servers: Map<String, MCPServerProcess>
  tools: List<MCPClientTool>
  eventBus: EventBus
}

struct MCPServerProcess {
  config: MCPServerConfig
  // In a real implementation, this would hold the child process handle
  // and communicate via JSON-RPC over stdio
  connected: Bool
}

pub impl MCPClient {
  pub fn new(eventBus: EventBus): MCPClient {
    let client = MCPClient {
      servers: {},
      tools: [],
      eventBus: eventBus,
    }
    client.loadConfig()
    return client
  }

  // Load MCP configuration from project + user level
  fn loadConfig(self) {
    // Project-level config
    let projectConfig = "${cwd()}/.smallcode/mcp.json"
    if pathExists(projectConfig) {
      self.loadFromFile(projectConfig)
    }

    // User-level config
    let userConfig = "${homedir()}/.config/smallcode/mcp.json"
    if pathExists(userConfig) {
      self.loadFromFile(userConfig)
    }
  }

  fn loadFromFile(self, path: String) {
    let content = readFile(path)
    let config = parseJson(content)
    let servers = config.get("mcpServers") as Map<String, Any>? ?? {}

    for (name, serverRaw) in servers {
      let server = serverRaw as Map<String, Any>
      let cfg = MCPServerConfig {
        name: name,
        command: server.get("command") as String? ?? "",
        args: server.get("args") as List<String>? ?? [],
        env: server.get("env") as Map<String, String>? ?? {},
        disabled: server.get("disabled") as Bool? ?? false,
        autoApprove: server.get("autoApprove") as List<String>? ?? [],
      }

      if !cfg.disabled {
        self.servers.set(name, MCPServerProcess { config: cfg, connected: false })
      }
    }
  }

  // Connect to all configured servers and discover their tools
  pub fn connect(self) {
    for (name, server) in self.servers {
      if server.connected { continue }

      // Initialize the server (send initialize request)
      let initResult = self.sendRequest(name, "initialize", {})
      if initResult {
        server.connected = true

        // List tools
        let toolsResult = self.sendRequest(name, "tools/list", {})
        if toolsResult {
          let toolList = toolsResult.get("tools") as List<Map<String, Any>>? ?? []
          for tool in toolList {
            self.tools.push(MCPClientTool {
              serverName: name,
              name: tool.get("name") as String? ?? "",
              description: tool.get("description") as String? ?? "",
              inputSchema: tool.get("inputSchema") as Map<String, Any>? ?? {},
            })
          }
        }

        self.eventBus.emit("mcp.connected", { server: name, tools: self.tools.length })
      }
    }
  }

  // Register MCP tools into the main tool registry
  pub fn registerTools(self, registry: ToolRegistry) {
    for tool in self.tools {
      let toolName = "mcp_${tool.serverName}_${tool.name}"
      let params = schemaToParams(tool.inputSchema)

      registry.register(ToolDef {
        id: toolName,
        category: "mcp",
        description: "[${tool.serverName}] ${tool.description}",
        parameters: params,
        execute: |args, ctx| { self.callTool(tool.serverName, tool.name, args, ctx) },
      })
    }
  }

  // Call a tool on an MCP server
  pub fn callTool(self, serverName: String, toolName: String, args: Map<String, Any>, ctx: ToolContext): ToolResult {
    let result = self.sendRequest(serverName, "tools/call", {
      name: toolName,
      arguments: args,
    })

    if !result {
      return ToolResult {
        output: "",
        metadata: null,
        error: "MCP server '${serverName}' did not respond",
      }
    }

    let content = result.get("content") as List<Map<String, Any>>? ?? []
    let text = content
      .filter(|c| c.get("type") == "text")
      .map(|c| c.get("text") as String? ?? "")
      .join("\n")

    let isError = result.get("isError") as Bool? ?? false

    return ToolResult {
      output: text,
      metadata: { server: serverName, tool: toolName },
      error: if isError { text } else { null },
    }
  }

  // Get list of available MCP tools (for display)
  pub fn listTools(self): List<String> {
    return self.tools.map(|t| "[${t.serverName}] ${t.name}: ${t.description}")
  }

  // Send a JSON-RPC request to an MCP server
  fn sendRequest(self, serverName: String, method: String, params: Map<String, Any>): Map<String, Any>? {
    let server = self.servers.get(serverName)
    if !server { return null }

    // Build JSON-RPC request
    let request = toJson({
      jsonrpc: "2.0",
      id: randomHex(8),
      method: method,
      params: params,
    })

    // Execute the server command with the request piped to stdin
    let cmd = "${server.config.command} ${server.config.args.join(" ")}"
    let result = exec(cmd, {
      cwd: cwd(),
      timeout: 30000,
      shell: true,
      input: request,
      env: server.config.env,
    })

    if result.exitCode != 0 { return null }

    try {
      let response = parseJson(result.stdout)
      return response.get("result") as Map<String, Any>?
    } catch {
      return null
    }
  }
}

// Convert JSON Schema to our ToolParam list
fn schemaToParams(schema: Map<String, Any>): List<ToolParam> {
  let params = []
  let properties = schema.get("properties") as Map<String, Any>? ?? {}
  let required = schema.get("required") as List<String>? ?? []

  for (name, prop) in properties {
    let propMap = prop as Map<String, Any>
    params.push(ToolParam {
      name: name,
      type: propMap.get("type") as String? ?? "string",
      description: propMap.get("description") as String? ?? "",
      required: required.contains(name),
      default: null,
    })
  }

  return params
}
