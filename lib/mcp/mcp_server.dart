import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:proxypin/mcp/mcp_config.dart';
import 'package:proxypin/mcp/mcp_tool.dart';
import 'package:proxypin/network/util/logger.dart';

/// MCP Server — 轻量 JSON-RPC over HTTP。
///
/// 端点：
///   GET  /health                   健康检查
///   GET  /sse                       SSE 端点（旧版兼容）
///   POST /mcp                       Streamable HTTP（主流，minis-mcp-cli 使用）
class McpServer {
  HttpServer? _server;
  final Map<String, McpToolDefinition> _tools = {};

  bool get isRunning => _server != null;

  Map<String, McpToolDefinition> get tools => _tools;

  void registerAll(List<McpToolDefinition> defs) {
    for (final d in defs) {
      _tools[d.name] = d;
    }
  }

  Future<bool> start(McpConfig config) async {
    if (_server != null) return true;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, config.port);
      _server = server;
      config.running = true;
      logger.d('MCP server started on port ${config.port}');
      unawaited(_serveLoop(server));
      return true;
    } catch (e, t) {
      config.running = false;
      logger.e('MCP server start failed', error: e, stackTrace: t);
      return false;
    }
  }

  Future<void> stop() async {
    try {
      if (_server != null) {
        await _server!.close(force: true);
        _server = null;
      }
    } catch (_) {}
  }

  Future<void> _serveLoop(HttpServer server) async {
    await for (final request in server) {
      unawaited(_dispatch(request).catchError((_) {}));
    }
  }

  Future<void> _dispatch(HttpRequest request) async {
    try {
      const originAsterisk = '*';
      request.response.headers.set('Access-Control-Allow-Origin', originAsterisk);
      request.response.headers.set('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
      request.response.headers.set('Access-Control-Allow-Headers',
          'Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id, Authorization');

      final path = request.uri.path;
      final method = request.method;

      if (method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      if (method == 'GET' && path == '/health') {
        await _writeJson(request.response, {'status': 'ok', 'running': _server != null});
        return;
      }

      if (method == 'POST' && path == '/mcp') {
        await _handleRpc(request);
        return;
      }

      // SSE 握手（旧版客户端）
      if (method == 'GET' && (path == '/sse')) {
        request.response.headers.contentType = ContentType('text', 'event-stream');
        request.response.headers.set('Cache-Control', 'no-cache');
        request.response.write('event: endpoint\r\ndata: /mcp\r\n\r\n');
        await Future.delayed(const Duration(seconds: 30));
        await request.response.close();
        return;
      }

      await _writeJson(
          request.response,
          {'jsonrpc': '2.0', 'error': {'code': -32601, 'message': 'Not found'}, 'id': null},
          status: HttpStatus.notFound);
    } catch (e) {
      logger.e('mcp dispatch error', error: e);
    }
  }

  Future<void> _handleRpc(HttpRequest request) async {
    dynamic body;
    try {
      final text = await utf8.decoder.bind(request).join();
      body = text.isEmpty ? null : jsonDecode(text);
    } catch (e) {
      await _writeJson(
          request.response,
          {'jsonrpc': '2.0', 'error': {'code': -32700, 'message': 'Parse error'}, 'id': null},
          status: HttpStatus.badRequest);
      return;
    }

    if (body is List) {
      final results = <dynamic>[];
      for (final item in body) {
        final r = await _processRpc(item as Map<String, dynamic>?);
        if (r != null) results.add(r); // 通知类(返回null)在批量中跳过，不回 body
      }
      await _writeJson(request.response, results);
      return;
    }

    final result = await _processRpc(body as Map<String, dynamic>?);
    if (result == null) {
      // MCP 通知类（notifications/*）:服务端按规范不返回任何内容，用 204 空响应。
      // 若写 200+body:null, 严格客户端(kotlinx sdk)反序列化会抛
      // "JsonNull is not a JsonObject"(rikkahub 连不上 pin 的根因)。
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    await _writeJson(request.response, result);
  }

  Future<dynamic> _processRpc(Map<String, dynamic>? body) async {
    if (body == null) {
      return {'jsonrpc': '2.0', 'error': {'code': -32600, 'message': 'Invalid Request'}, 'id': null};
    }
    final id = body['id'];
    final method = body['method'] as String?;

    switch (method) {
      case 'initialize':
        return {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': '2025-03-26',
            'capabilities': {'tools': {'listChanged': false}},
            'serverInfo': {'name': 'proxypin-mcp', 'version': '1.3.1'},
          }
        };
      case 'notifications/initialized':
        return null; // 通知类无响应
      case 'ping':
        return {'jsonrpc': '2.0', 'id': id, 'result': {}};
      case 'tools/list':
        return {
          'jsonrpc': '2.0',
          'id': id,
          'result': {'tools': _tools.values.map((d) => d.toSchema()).toList()}
        };
      case 'tools/call':
        return await _handleToolCall(id, body['params'] as Map<String, dynamic>? ?? {});
      case 'resources/list':
        return {'jsonrpc': '2.0', 'id': id, 'result': {'resources': []}};
      default:
        return {'jsonrpc': '2.0', 'id': id, 'error': {'code': -32601, 'message': 'Method not found: $method'}};
    }
  }

  Future<dynamic> _handleToolCall(dynamic id, Map<String, dynamic> params) async {
    final name = params['name'] as String?;
    final rawArgs = params['arguments'];

    Map<String, dynamic> arguments;
    if (rawArgs is String) {
      try {
        arguments = jsonDecode(rawArgs) as Map<String, dynamic>;
      } catch (_) {
        arguments = <String, dynamic>{};
      }
    } else if (rawArgs is Map) {
      arguments = Map<String, dynamic>.from(rawArgs);
    } else {
      arguments = <String, dynamic>{};
    }

    final def = _tools[name];
    if (def == null || name == null) {
      return {'jsonrpc': '2.0', 'id': id, 'error': {'code': -32602, 'message': 'Tool not found: $name'}};
    }

    try {
      final result = await def.handler(arguments);
      final text = result is String ? result : jsonEncode(result);
      return {
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'content': [
            {'type': 'text', 'text': text}
          ]
        }
      };
    } catch (e, t) {
      logger.e('mcp tool $name error', error: e, stackTrace: t);
      return {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32603, 'message': 'Tool error: ${e.toString()}'}
      };
    }
  }

  Future<void> _writeJson(HttpResponse response, dynamic data, {int status = 200}) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    await response.close();
  }
}
