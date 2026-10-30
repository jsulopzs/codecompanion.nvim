---
description: "Check which parts of the Agent Client Protocol (ACP) CodeCompanion implements, and how it talks to agents."
---

# Agent Client Protocol (ACP)

The [Agent Client Protocol (ACP)](https://agentclientprotocol.com/) is an open standard for connecting editors to coding agents. CodeCompanion implements it so you can work with agents like Claude Code and Codex from the chat buffer. This page lists what's supported and how it's implemented. To set up an agent, see [Configuring ACP Adapters](/configuration/adapters-acp).

## Implementation

| Feature | Supported | Details |
|---|---|---|
| **Core Protocol** | ✅ | JSON-RPC 2.0, streaming responses, message buffering |
| **Authentication** | ✅ | Multiple auth methods, adapter-level hooks |
| **Content Types** | ✅ | Text and images |
| **File System** | ✅ | Read and write text files, with line ranges |
| **MCP Integration** | ✅ | Passes your [MCP servers](/configuration/adapters-acp#configuring-mcp-servers) to the agent |
| **Permissions** | ✅ | Approve tool calls, with a diff preview for edits |
| **Session Management** | ✅ | Create, list and load sessions |
| **Session Config Options** | ✅ | Switch the agent's mode, model and other options |
| **Tool Calls** | ✅ | Content blocks, file diffs, status updates |
| **Agent Plans** | ✅ | Show an agent's execution plan |
| **Terminal Operations** | ❌ | Give the agent a Neovim terminal |

### Client Capabilities

CodeCompanion advertises these capabilities to agents:

```lua
{
  fs = {
    readTextFile = true,
    writeTextFile = true,
  },
  _meta = {
    jetbrains = {
      air = { version = 1, capabilities = { "asyncTasks" } },
    },
  },
}
```

### Content Types

| Content Type | Send to Agent | Receive from Agent |
|---|---|---|
| Text | ✅ | ✅ |
| File Diffs | N/A | ✅ |
| Images | ✅ | ❌ |
| Audio | ❌ | ❌ |
| Embedded Resources | ❌ | ✅ |

An embedded resource from an agent is shown as its text, or its URI if it has no text. Images and audio from an agent are shown as `[image]` and `[audio]`.

### State Management

HTTP adapters are stateless and send the full conversation with every request. ACP agents are stateful: the agent holds the conversation, so CodeCompanion only sends new messages with each prompt and tracks the session ID throughout.

### Files and Buffers

A file or buffer shared with an agent is sent as its path, not its content, and the agent reads it itself. This avoids the `<attachment>` tags that CodeCompanion uses for HTTP adapters.

### Slash Commands

Agents can advertise their own slash commands. Type `\` in the chat buffer to complete them, and CodeCompanion turns `\command` into `/command` before sending your prompt.

### Session Config Options

Agents expose their modes, models and other settings as [session config options](https://agentclientprotocol.com/protocol/session-config-options). CodeCompanion changes them with `session/set_config_option`. Change models with `ga` in the chat buffer, and anything else with the [/acp_session_options](/usage/chat-buffer/slash-commands#acp-session-options) slash command.

### Session Resume

If an agent supports `session/list` and `session/load`, the [/resume](/usage/chat-buffer/slash-commands#resume) slash command lists its previous sessions and restores the one you pick into the chat buffer.

To open a chat on a session from Lua, pass its ID to `acp_session_id`. If the agent also supports `session/fork`, pass it to `acp_fork_session_id` instead, and the chat continues in a new fork of that session, leaving the original untouched:

```lua
require("codecompanion.interactions.chat").new({ adapter = "claude_code", acp_fork_session_id = "<session-id>" })
```

If the session can't be loaded or forked, the chat starts a new one.

### Autonomous Turns

Some agents continue working after a prompt has ended. Claude Code can resume when a background command finishes, a scheduled wakeup fires or a cron task runs. CodeCompanion shows those updates as a new agent turn, keeps the chat busy until it ends and preserves any unsent text below a new user header. Press `q` to cancel the turn.

CodeCompanion advertises the JetBrains AIR `asyncTasks` capability through `clientCapabilities._meta.jetbrains.air`. Claude Code uses this non-standard extension to mark the start and end of an autonomous turn and to report its cause. If an agent sends content without these marks, CodeCompanion closes the turn after a configurable idle period. The extension can be removed when ACP v2 supports updates outside a prompt. Codex does not currently send autonomous turns.

### Cleanup

CodeCompanion disconnects from agents on Neovim's `VimLeavePre` autocmd, so their processes are stopped when Neovim exits.

## Protocol Version

CodeCompanion implements **ACP protocol version 1**.

The version is negotiated during initialisation. If an agent selects a different version, CodeCompanion logs a warning and carries on with the agent's version.

## Limitations

- **System prompts** - ACP has no way to send a system prompt. CodeCompanion doesn't merge its own into your messages either, so an agent behaves as it would if you used it directly
- **Terminal operations** - The `terminal/*` methods aren't implemented, and CodeCompanion doesn't advertise a terminal capability
- **Audio** - Audio can't be sent or received

## See Also

- [Agent Client Protocol Specification](https://agentclientprotocol.com/) - The official ACP documentation
- [Configuring ACP Adapters](/configuration/adapters-acp) - Setup instructions for each agent
- [Using Agents and Tools](/usage/chat-buffer/agents-tools) - Working with agents in the chat buffer
