import 'dart:async';
import 'dart:convert';

import 'package:proxypin/network/components/interceptor.dart';
import 'package:proxypin/network/components/manager/environment_manager.dart';
import 'package:proxypin/network/components/manager/request_breakpoint_manager.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/util/cache.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/ui/component/multi_window.dart';

import '../http/http_headers.dart';

class RequestBreakpointInterceptor extends Interceptor {
  static RequestBreakpointInterceptor instance = RequestBreakpointInterceptor._();

  final manager = RequestBreakpointManager.instance;

  final ExpiringCache<String, Completer<HttpRequest?>> _pausedRequests = ExpiringCache(Duration(minutes: 10));
  final ExpiringCache<String, Completer<HttpResponse?>> _pausedResponses = ExpiringCache(Duration(minutes: 10));

  /// 挂起中的请求/响应快照数据(toJson),用于 MCP 查看与放行。
  /// 与 _pausedRequests/_pausedResponses 同 key(requestId),互不冲突。
  final ExpiringCache<String, Map<String, dynamic>> _pausedRequestData =
      ExpiringCache(Duration(minutes: 10));
  final ExpiringCache<String, Map<String, dynamic>> _pausedResponseData =
      ExpiringCache(Duration(minutes: 10));

  RequestBreakpointInterceptor._();

  /// 用环境变量渲染 {{name}}。若 EnvironmentManager 未加载或未启用,返回原字符串。
  static String? _renderEnv(String? input) => EnvironmentManager.tryRender(input);

  /// 渲染 headers 里所有值中的 {{var}}。多值 header(如 Set-Cookie)每个值独立渲染,不丢值。
  static void _renderHeadersInPlace(HttpHeaders headers) {
    if (EnvironmentManager.instanceOrNull?.enabled != true) return;
    // 先收集需要重写的 (name, renderedList),避免边遍历边改
    final rewrites = <String, List<String>>{};
    headers.forEach((name, values) {
      if (!values.any((v) => v.contains('{{'))) return;
      rewrites[name] = values.map((v) => _renderEnv(v) ?? v).toList();
    });
    // 用 remove + add 重建每个多值列表,保留全部值
    rewrites.forEach((name, values) {
      headers.remove(name);
      for (final v in values) {
        headers.add(name, v);
      }
    });
  }

  /// 渲染 body 里的 {{var}}。仅在 body 看起来是"较小的文本"时才尝试解码替换,
  /// 二进制/大 body/无变量占位时保持原字节不动,避免破坏和无谓的 decode 开销。
  static const int _renderBodyMaxSize = 512 * 1024; // 512KB 以上跳过

  /// 已知的二进制/非文本 MIME 前缀,遇到直接跳过 render
  static const List<String> _binaryContentTypes = [
    'image/',
    'video/',
    'audio/',
    'application/octet-stream',
    'application/zip',
    'application/x-protobuf',
    'application/x-msgpack',
    'application/pdf',
    'font/',
  ];

  static bool _looksBinary(String? contentType) {
    if (contentType == null || contentType.isEmpty) return false;
    final ct = contentType.toLowerCase();
    return _binaryContentTypes.any(ct.startsWith);
  }

  static List<int>? _renderBody(List<int>? body, String? charset, {String? contentType}) {
    if (body == null || body.isEmpty) return body;
    if (EnvironmentManager.instanceOrNull?.enabled != true) return body;
    if (body.length > _renderBodyMaxSize) return body;
    if (_looksBinary(contentType)) return body;
    try {
      final text = (charset == 'utf-8' || charset == 'utf8' || charset == null)
          ? utf8.decode(body)
          : String.fromCharCodes(body);
      if (!text.contains('{{')) return body;
      final rendered = _renderEnv(text) ?? text;
      return (charset == 'utf-8' || charset == 'utf8' || charset == null)
          ? utf8.encode(rendered)
          : rendered.codeUnits;
    } catch (_) {
      return body; // 非法文本,原样返回
    }
  }

  @override
  Future<HttpRequest?> onRequest(HttpRequest request) async {
    RequestBreakpointManager requestBreakpointManager = await manager;
    if (!requestBreakpointManager.enabled) return request;

    var url = request.requestUrl;
    for (var rule in requestBreakpointManager.list) {
      if (rule.match(url, method: request.method) && rule.interceptRequest) {
        Completer<HttpRequest?> completer = Completer();
        _pausedRequests[request.requestId] = completer;
        _pausedRequestData[request.requestId] = request.toJson();

        // Open Breakpoint Executor Window
        MultiWindow.openWindow("Breakpoint - Request", 'BreakpointExecutor',
            args: {'type': 'request', 'request': request.toJson(), 'requestId': request.requestId});

        return completer.future.then((req) {
          if (req == null) {
            logger.d('Request ${request.requestId} was resumed null, aborting request');
            return null;
          }

          request.method = req.method;
          // 先渲染 URI 中的 {{var}}(如 host / path / query 里可能用到)
          final renderedUri = _renderEnv(req.uri) ?? req.uri;
          Uri uri = Uri.parse(renderedUri);
          // 放行时支持跨域改道:若新的 uri 是完整 URL(含 host),记录目标 host,稍后同步更新 Host 头与连接目标。
          HostAndPort? newHp;
          if (uri.host.isNotEmpty) {
            newHp = HostAndPort.of(renderedUri);
            request.hostAndPort = newHp;
            request.uri = uri.path + (uri.hasQuery ? "?${uri.query}" : "");
          } else {
            if (uri.isScheme('https')) {
              request.uri = uri.path + (uri.hasQuery ? "?${uri.query}" : "");
            } else {
              request.uri = uri.toString();
            }
          }

          request.headers.clear();
          request.headers.addAll(req.headers);
          // 跨域改道时覆盖 Host 头为目标 host(代理按 Host 头路由连接)
          if (newHp != null) {
            final hostHeader =
                newHp.host + ((newHp.port != 80 && newHp.port != 443) ? ":${newHp.port}" : "");
            request.headers.set(HttpHeaders.HOST, hostHeader);
          }
          _renderHeadersInPlace(request.headers);
          _renderHeadersInPlace(request.headers);
          request.headers.remove(HttpHeaders.CONTENT_ENCODING);

          request.body = _renderBody(req.body, request.charset, contentType: request.headers.contentType);
          logger.d('Resuming request ${request.requestId} with modified request');
          return request;
        });
      }
    }
    return request;
  }

  @override
  Future<HttpResponse?> onResponse(HttpRequest request, HttpResponse response) async {
    RequestBreakpointManager requestBreakpointManager = await manager;
    if (!requestBreakpointManager.enabled) return response;

    var url = request.requestUrl;
    for (var rule in requestBreakpointManager.list) {
      if (rule.match(url, method: request.method) && rule.interceptResponse) {
        Completer<HttpResponse?> completer = Completer();
        _pausedResponses[request.requestId] = completer;
        _pausedResponseData[request.requestId] = response.toJson();

        // Open Breakpoint Executor Window
        MultiWindow.openWindow("Breakpoint - Response", 'BreakpointExecutor', args: {
          'type': 'response',
          'request': request.toJson(),
          'response': response.toJson(),
          'requestId': request.requestId
        });

        return completer.future.then((res) {
          if (res == null) {
            return null;
          }

          response.status = res.status;
          response.headers.clear();
          response.headers.addAll(res.headers);
          _renderHeadersInPlace(response.headers);
          response.headers.remove(HttpHeaders.CONTENT_ENCODING);

          response.body = _renderBody(res.body, response.charset, contentType: response.headers.contentType);

          logger.d('Resuming response for request ${request.requestId} with modified response');
          return response;
        });
      }
    }
    return response;
  }

  void resumeRequest(String requestId, HttpRequest? request) {
    if (_pausedRequests.containsKey(requestId)) {
      _pausedRequests.remove(requestId)?.complete(request);
    }
  }

  void resumeResponse(String requestId, HttpResponse? response) {
    if (_pausedResponses.containsKey(requestId)) {
      _pausedResponses.remove(requestId)?.complete(response);
    }
  }

  // ---- MCP 支持: 查看/放行/中止挂起断点 ----

  /// 挂起中的请求 requestId 列表。
  List<String> pendingRequestIds() => _pausedRequests.keys.toList();

  /// 挂起中的响应 requestId 列表。
  List<String> pendingResponseIds() => _pausedResponses.keys.toList();

  /// 挂起请求的摘要信息(用于 MCP 列表展示)。
  Map<String, dynamic>? pendingRequestSummary(String requestId) {
    final data = _pausedRequestData[requestId];
    if (data == null) return null;
    final headers = data['headers'] is Map ? (data['headers'] as Map).cast<String, dynamic>() : null;
    return {
      'requestId': requestId,
      'type': 'request',
      'method': data['method'],
      'url': data['uri'],
      'host': headers?['host'],
      'pausedMs': 0,
    };
  }

  /// 挂起响应的摘要信息。
  Map<String, dynamic>? pendingResponseSummary(String requestId) {
    final data = _pausedResponseData[requestId];
    if (data == null) return null;
    final req = _pausedRequestData[requestId];
    return {
      'requestId': requestId,
      'type': 'response',
      'method': req?['method'],
      'url': req?['uri'],
      'status': data['status'],
    };
  }

  /// 放行一个挂起的请求。modify 为空时按原样放行;
  /// 提供 modify 时,其中的 method/uri/headers/body 会覆盖原值。
  bool releaseRequestById(String requestId, {Map<String, dynamic>? modify}) {
    if (!_pausedRequests.containsKey(requestId)) return false;
    final raw = _pausedRequestData[requestId];
    if (raw == null) return false;
    try {
      final merged = Map<String, dynamic>.from(raw);
      if (modify != null) merged.addAll(modify);
      final request = HttpRequest.fromJson(merged);
      resumeRequest(requestId, request);
      _pausedRequestData.remove(requestId);
      return true;
    } catch (_) {
      // 构造失败则原样放行
      resumeRequest(requestId, HttpRequest.fromJson(raw));
      _pausedRequestData.remove(requestId);
      return true;
    }
  }

  /// 放行一个挂起的响应。modify 为空时按原样放行。
  bool releaseResponseById(String requestId, {Map<String, dynamic>? modify}) {
    if (!_pausedResponses.containsKey(requestId)) return false;
    final raw = _pausedResponseData[requestId];
    if (raw == null) return false;
    try {
      final merged = Map<String, dynamic>.from(raw);
      if (modify != null) merged.addAll(modify);
      final response = HttpResponse.fromJson(merged);
      resumeResponse(requestId, response);
      _pausedResponseData.remove(requestId);
      return true;
    } catch (_) {
      resumeResponse(requestId, HttpResponse.fromJson(raw));
      _pausedResponseData.remove(requestId);
      return true;
    }
  }

  /// 中止(丢弃)一个挂起的请求。返回 true 表示存在且已中止。
  bool abortRequestById(String requestId) {
    if (!_pausedRequests.containsKey(requestId)) return false;
    _pausedRequestData.remove(requestId);
    resumeRequest(requestId, null);
    return true;
  }

  /// 中止(丢弃)所有挂起的请求。
  int abortAllRequests() {
    final ids = _pausedRequests.keys.toList();
    for (final id in ids) {
      _pausedRequestData.remove(id);
      resumeRequest(id, null);
    }
    return ids.length;
  }
}
