import 'package:proxypin/mcp/mcp_config.dart';
import 'package:proxypin/mcp/mcp_server.dart';
import 'package:proxypin/mcp/mcp_tools.dart';

/// MCP 协调器：装配 server + 工具注册表，统一启动/停止入口。
/// UI（设置页）与 App 启动处都通过它控制 MCP 服务生命周期。
class McpManager {
  static McpManager? _instance;

  final McpConfig config;
  final McpServer server = McpServer();
  bool _toolsRegistered = false;

  McpManager._(this.config);

  static Future<McpManager> get instance async {
    _instance ??= McpManager._(await McpConfig.instance);
    return _instance!;
  }

  /// 注册全部工具（首次调用时执行一次）
  Future<void> _ensureTools() async {
    if (_toolsRegistered) return;
    final defs = await buildMcpTools();
    server.registerAll(defs);
    _toolsRegistered = true;
  }

  bool get isRunning => server.isRunning;

  Future<bool> start() async {
    await _ensureTools();
    return server.start(config);
  }

  Future<void> stop() async {
    await server.stop();
  }

  /// 若配置了自启动则启动（App 启动时调用）
  Future<void> autoStartIfEnabled() async {
    if (config.autoStart) {
      await start();
    }
  }

  Future<void> setPort(int port) async {
    config.port = port;
    await config.flush();
  }

  Future<void> setAutoStart(bool v) async {
    config.autoStart = v;
    await config.flush();
  }
}
