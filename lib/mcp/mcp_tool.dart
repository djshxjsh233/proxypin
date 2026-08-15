/// 单条 MCP 工具定义：一个工具包含 schema(供 tools/list) 和 handler(供 tools/call)。
class McpToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) handler;

  McpToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
  });

  /// 转成 MCP tools/list 需要的 schema 形式
  Map<String, dynamic> toSchema() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
      };
}
