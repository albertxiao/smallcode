// SmallCode - MCP Server
// Exposes SmallCode as a Model Context Protocol server
// Other agents (Kiro, Claude Code, etc.) can call SmallCode tools via MCP

import { Session } from "./session"
import { ToolRegistry, ToolResult, ToolContext } from "../tools/registry"
import { BudgetEngine } from "../context/budget"
import { EventBus } from "./event_bus"
import { cwd } from "std/env"

// MCP Protocol types
pub struct MCPServerInfo {
  name: String
  version: String
  capabilities: MCPCapabilities
}

pub struct MCPCapabilities {
  tools: Bool
  resources: Bool
  prompts: Bool
}

pub struct MCPToolDef {
  name: String
  description: String
  inputSchema: Map<String, Any>
}

pub struct MCPToolCallRequest {
  method: String
  params: MCPToolCallParams
}

pub struct MCPToolCallParams {
  name: String
  arguments: Map<String, Any>
}

pub struct MCPToolCallResponse {
  content: List<MCPContent>
  isError: Bool
}

pub struct MCPContent {
  type: String    // "text"
  text: String
}

pub struct MCPServer {
  registry: ToolRegistry
  budget: BudgetEngine
  eventBus: EventBus
  session: Session?
}

pub impl MCPServer {
  pub fn new(registry: ToolRegistry, budget: BudgetEngine, eventBus: EventBus): MCPServer {
    return MCPServer {
      registry: registry,
      budget: budget,
      eventBus: eventBus,
      session: null,
    }
  }

  pub fn setSession(self, session: Session) {
    self.session = session
  }

  // Handle initialize request
  pub fn handleInitialize(self): MCPServerInfo {
    return MCPServerInfo {
      name: "smallcode",
      version: "0.1.0",
      capabilities: MCPCapabilities {
        tools: true,
        resources: true,
        prompts: false,
      },
    }
  }

  // Handle tools/list request
  pub fn handleListTools(self): List<MCPToolDef> {
    let tools = self.registry.active()
    return tools.map(|t| {
      let properties = {}
      let required = []
      for param in t.parameters {
        properties.set(param.name, {
          type: param.type,
          description: param.description,
        })
        if param.required { required.push(param.name) }
      }

      return MCPToolDef {
        name: "smallcode_${t.id}",
        description: t.description,
        inputSchema: {
          type: "object",
          properties: properties,
          required: required,
        },
      }
    })
  }

  // Handle tools/call request
  pub fn handleToolCall(self, request: MCPToolCallRequest): MCPToolCallResponse {
    let toolName = request.params.name.replace("smallcode_", "")
    let args = request.params.arguments

    let ctx = ToolContext {
      cwd: cwd(),
      budget: self.budget,
      sessionId: "mcp_session",
    }

    let result = self.registry.get(toolName)
    if !result {
      return MCPToolCallResponse {
        content: [MCPContent { type: "text", text: "Unknown tool: ${toolName}" }],
        isError: true,
      }
    }

    let tool = result
    let execResult = tool.execute(args, ctx)

    if execResult.error {
      return MCPToolCallResponse {
        content: [MCPContent { type: "text", text: "Error: ${execResult.error}\n${execResult.output}" }],
        isError: true,
      }
    }

    return MCPToolCallResponse {
      content: [MCPContent { type: "text", text: execResult.output }],
      isError: false,
    }
  }

  // Handle a full agent prompt via MCP (higher-level than individual tools)
  pub fn handleAgentPrompt(self, userMessage: String): MCPToolCallResponse {
    if !self.session {
      return MCPToolCallResponse {
        content: [MCPContent { type: "text", text: "Session not initialized" }],
        isError: true,
      }
    }

    let response = self.session.runOnce(userMessage)
    return MCPToolCallResponse {
      content: [MCPContent { type: "text", text: response }],
      isError: false,
    }
  }

  // Run the MCP server via stdio (JSON-RPC over stdin/stdout)
  pub fn runStdio(self) {
    // Read JSON-RPC messages from stdin, dispatch, write responses to stdout
    while true {
      let line = readStdinLine()
      if line.isEmpty() { break }

      let request = parseJson(line)
      let response = self.dispatch(request)
      let output = toJson(response)
      println(output)
    }
  }

  fn dispatch(self, request: Map<String, Any>): Map<String, Any> {
    let method = request.get("method") as String? ?? ""
    let id = request.get("id")

    let result = match method {
      "initialize" => toJson(self.handleInitialize())
      "tools/list" => toJson(self.handleListTools())
      "tools/call" => {
        let params = MCPToolCallParams {
          name: request.get("params").get("name") as String,
          arguments: request.get("params").get("arguments") as Map<String, Any>,
        }
        let req = MCPToolCallRequest { method: method, params: params }
        toJson(self.handleToolCall(req))
      }
      "smallcode/agent" => {
        let message = request.get("params").get("message") as String
        toJson(self.handleAgentPrompt(message))
      }
      _ => toJson({ error: "Unknown method: ${method}" })
    }

    return {
      jsonrpc: "2.0",
      id: id,
      result: parseJson(result),
    }
  }
}
