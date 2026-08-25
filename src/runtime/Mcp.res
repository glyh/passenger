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

// The client half, for the live checks. They drive this server the way a real
// client does -- over stdio, as a subprocess -- rather than calling into it,
// which is the only way to exercise the transport and the schemas at all.
type client
type clientTransport

@module("@modelcontextprotocol/sdk/client/index.js") @new
external client: {..} => client = "Client"

@module("@modelcontextprotocol/sdk/client/stdio.js") @new
external stdioClient: {..} => clientTransport = "StdioClientTransport"

@send external connectClient: (client, clientTransport) => promise<unit> = "connect"
@send external closeClient: client => promise<unit> = "close"
@send external listTools: client => promise<{"tools": array<{"name": string}>}> = "listTools"
@send
external callTool: (client, {..}) => promise<{"content": array<{"text": string}>}> = "callTool"
