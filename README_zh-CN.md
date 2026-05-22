# SmallCode

[![npm](https://img.shields.io/npm/v/smallcode)](https://www.npmjs.com/package/smallcode)

**为小型 LLM（≤20B 参数）优化的 AI 编程代理**

SmallCode 是一款终端原生编程代理，专为在消费级硬件上运行的本地模型（7B-20B）量身设计，旨在充分发挥小型模型的能力。当 OpenCode 等工具假设你拥有 128k+ 上下文和完美工具调用能力的前沿模型时，SmallCode 通过智能架构来弥补小型模型的局限性。

## 为什么选择 SmallCode？

| | OpenCode | SmallCode |
|---|----------|-----------|
| **目标模型** | 前沿模型（Claude, GPT-4） | 7B-20B 本地模型 |
| **上下文管理** | 全量注入 | 预算管理，自动摘要 |
| **工具调用** | 假设可靠的 JSON | 宽容的多格式解析器 |
| **任务规划** | 单次生成 | TODO 文件分解步骤 |
| **编辑方式** | 全文件写入 | 搜索替换补丁 |
| **隐私保护** | API 调用到云端 | 完全本地，无需网络 |

## 快速开始

```bash
# 全局安装
npm install -g smallcode

# 或直接使用 npx 运行
npx smallcode

# 在项目目录中启动
cd my-project
smallcode
```

SmallCode 包含 [BoneScript](https://github.com/Doorman11991/BoneScript) 和 [budget-aware-mcp](https://github.com/Doorman11991/budget-aware-mcp) 作为依赖——一次安装全部搞定。

### 环境要求

- Node.js 18+
- 本地 LLM 服务器（LM Studio、Ollama 或任何 OpenAI 兼容的端点）

### 配置

在项目根目录创建 `.env` 文件：

```bash
# 必填
SMALLCODE_MODEL=your-model-name
SMALLCODE_BASE_URL=http://localhost:1234/v1

# 可选：模型升级（硬失败时自动回退到云端）
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...
# DEEPSEEK_API_KEY=sk-...
```

查看 `.env.example` 了解所有选项。同时支持 `smallcode.toml` 以保持向后兼容。

## 架构

SmallCode 采用模块化架构：

```
bin/
├── smallcode.js        主入口 + 代理循环
├── governor.js         工具评分、验证、分解
├── escalation.js       云端模型回退（Claude/OpenAI）
├── commands.js         TUI 斜杠命令
├── tui.js              经典 TUI 渲染器
└── bonescript_guide.js BoneScript 语法参考

src/
├── tui/fullscreen.js   全屏交替缓冲区 TUI
├── plugins/loader.js   插件系统
├── plugins/skills.js   技能系统
├── tools/builtin/      工具实现
├── governor/           验证器、评分器、硬失败
└── core/               配置、事件、会话
```

## 核心特性

### BoneScript 集成
对于 Node.js/TypeScript 后端，SmallCode 使用 BoneScript——编写一个 `.bone` 文件即可编译为完整项目（路由、认证、数据库、事件、迁移、SDK、管理面板、Docker、CI）。将 8-15 次工具调用减少到 1-2 次，显著提升小型模型的可靠性。

### 模型升级
当本地模型在重试 + 分解后仍然硬失败时，SmallCode 可以选择升级到更强的云端模型（Claude、OpenAI、DeepSeek）。完全可选——需要 API 密钥。会话限制防止费用失控。

**升级目标**（云端，仅在硬失败时使用）：
- Claude Sonnet 4.5 / 4.6, Haiku 4.5
- GPT-5.4 Mini / Nano
- DeepSeek V4 / V4 Pro / V4 Flash

### 上下文预算引擎
永远不会超出模型的上下文窗口。自动将大文件摘要为签名，驱逐旧消息，并实时追踪 token 使用量。

### 两阶段工具路由
将 Schema 上下文开销减半。模型先选择一个类别（读/写/搜索/运行/规划），然后只获取相关的工具 Schema。对于 8-16k 上下文的模型至关重要。

### 宽容的工具调用解析器
小型模型生成的输出常常格式混乱。SmallCode 可以从 JSON、YAML、XML、Hermes 格式或纯文本中解析工具调用。自动修复常见错误（参数名错误、类型不匹配）。

### TODO 驱动规划
复杂任务被分解为原子步骤。模型每轮读取 TODO 文件以了解当前进度。每个步骤在继续前都会经过验证（lint/编译）。

### 补丁优先编辑
以搜索替换作为主要编辑原语。小型模型无法可靠地重现整个文件——它们会截断、幻觉或偏移。`patch` 更安全、更节省上下文。

### 早停检测
检测重复循环和失控输出。当小型模型开始原地打转时，节省 token 和时间。

### 模型配置文件
每个模型的配置：上下文长度、工具格式（native/hermes/json/xml/text）、聊天模板、优缺点。自动适配提示策略。

### 工作记忆
跨轮次持久化的便签本。弥补有限的推理深度——模型可以给自己写笔记。


## 命令

| 命令 | 描述 |
|---------|-------------|
| `/quit`, `/q` | 退出 SmallCode |
| `/clear` | 重置对话 |
| `/stats` | 显示会话统计 |
| `/memory` | 显示工作记忆 |
| `/plan` | 显示当前任务计划 |
| `/model` | 显示/切换模型 |
| `/skill` | 管理可复用技能 |
| `/plugin` | 安装/管理插件 |
| `/sessions` | 列出/恢复已保存的会话 |
| `/help` | 显示所有命令 |

## 工具

| 工具 | 描述 |
|------|-------------|
| `bone_compile` | 将 .bone 编译为完整的后端项目 |
| `bone_check` | 验证 .bone 文件（类型错误、约束） |
| `list_projects` | 列出所有已索引项目及统计 |
| `graph_search` | 代码图符号搜索 |
| `explain_symbol` | 完整符号解释（调用者、被调用者） |
| `read_file` | 读取文件内容 |
| `write_file` | 创建/覆盖文件 |
| `patch` | 搜索替换编辑 |
| `bash` | 运行 Shell 命令 |
| `search` | 正则搜索（ripgrep） |
| `find_files` | Glob 文件搜索 |
| `memory_load` | 加载相关项目记忆 |
| `memory_remember` | 保存知识到记忆 |
| `web_search` | 通过 DuckDuckGo 搜索网页（需要 `SMALLCODE_WEB_BROWSE=true`） |
| `web_fetch` | 获取并提取 URL 文本（需要 `SMALLCODE_WEB_BROWSE=true`） |

### 网页浏览

SmallCode 包含 Playwright 隐身模式，用于不被检测的网页浏览。默认禁用——对能有效综合网页上下文的中/大型模型（20B+）启用：

```bash
# 在 .env 中设置
SMALLCODE_WEB_BROWSE=true
```

启用后，模型可以在任务期间搜索网页和获取文档。使用带反检测功能的无头 Chromium 来避免验证码和机器人拦截。如果 Playwright 不可用，则回退到简单的 HTTP 获取。

## 许可证

MIT
