// The MCP SDK's low-level Server, not McpServer: the high-level one takes zod
// schemas for every tool, and binding zod to describe a schema this side
// already has in JSON is a dependency bought for nothing.

type server
type transport
type schema

@module("@modelcontextprotocol/sdk/server/index.js") @new
external server: ({..}, {..}) => server = "Server"

@module("@modelcontextprotocol/sdk/server/stdio.js") @new
external stdio: unit => transport = "StdioServerTransport"

@module("@modelcontextprotocol/sdk/types.js")
external listToolsRequest: schema = "ListToolsRequestSchema"

@module("@modelcontextprotocol/sdk/types.js")
external callToolRequest: schema = "CallToolRequestSchema"

@send external setRequestHandler: (server, schema, 'req => promise<'res>) => unit =
  "setRequestHandler"

@send external connect: (server, transport) => promise<unit> = "connect"
