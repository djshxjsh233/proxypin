import 'dart:convert';
import 'dart:io';

import 'package:proxypin/storage/path.dart';
import 'package:proxypin/network/util/logger.dart';

/// MCP 服务配置（区别于全局 AppConfiguration，独立 json 文件存储）
class McpConfig {
  static McpConfig? _instance;

  /// 端口（默认 9010，与既有 pin MCP 对齐）
  int port = 9010;

  /// App 启动时自动开启 MCP 服务
  bool autoStart = false;

  /// MCP 服务状态（内存态，不落盘）
  bool running = false;

  static Future<McpConfig> get instance async {
    if (_instance == null) {
      _instance = McpConfig._internal();
      await _instance!._load();
    }
    return _instance!;
  }

  McpConfig._internal();

  Future<File> get _path async => Paths.getPath("mcp_config.json");

  Future<void> _load() async {
    try {
      final file = await _path;
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final json = jsonDecode(content) as Map<String, dynamic>;
          port = json['port'] ?? 9010;
          autoStart = json['autoStart'] ?? false;
        }
      }
    } catch (e, t) {
      logger.e('load mcp config error', error: e, stackTrace: t);
    }
  }

  Future<void> flush() async {
    try {
      final file = await _path;
      await file.writeAsString(jsonEncode(toJson()));
    } catch (e, t) {
      logger.e('save mcp config error', error: e, stackTrace: t);
    }
  }

  Map<String, dynamic> toJson() => {'port': port, 'autoStart': autoStart, 'running': running};
}
