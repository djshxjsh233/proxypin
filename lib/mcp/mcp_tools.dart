import 'dart:convert';

import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/manager/request_breakpoint_manager.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/ui/mobile/mobile.dart';
import 'package:proxypin/mcp/mcp_tool.dart';

/// 构建所有 MCP 工具定义。MCP server 通过 buildMcpTools() 一次性注册。
Future<List<McpToolDefinition>> buildMcpTools() async {
  return <McpToolDefinition>[
    // ---------------- 抓包查询 ----------------
    McpToolDefinition(
      name: 'get_request_list',
      description: '获取抓包请求列表（摘要）。支持按域名、方法、关键词过滤与分页。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'domain': {'type': 'string', 'description': '按域名过滤（模糊匹配）'},
          'method': {'type': 'string', 'description': '按 HTTP 方法过滤，如 GET、POST'},
          'keyword': {'type': 'string', 'description': '按 URL 关键词搜索'},
          'offset': {'type': 'integer', 'description': '分页偏移，默认 0'},
          'limit': {'type': 'integer', 'description': '每页数量，默认 50'},
        },
      },
      handler: toolGetRequestList,
    ),
    McpToolDefinition(
      name: 'get_request_detail',
      description: '获取某条抓包请求的完整详情（请求头、请求体、响应头、响应体）。index 为 get_request_list 结果中的序号。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer', 'description': '请求序号（get_request_list 返回列表中的下标）'},
        },
        'required': ['index'],
      },
      handler: toolGetRequestDetail,
    ),
    McpToolDefinition(
      name: 'search_requests',
      description: '按 URL 关键词 / Body 关键词搜索抓包请求，返回完整详情。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'urlKeyword': {'type': 'string', 'description': 'URL 中包含的关键词'},
          'bodyKeyword': {'type': 'string', 'description': '请求体或响应体中的关键词'},
          'limit': {'type': 'integer', 'description': '最大返回数，默认 50'},
        },
      },
      handler: toolSearchRequests,
    ),
    McpToolDefinition(
      name: 'get_request_stats',
      description: '抓包统计：总请求数、域名分布、状态码分布、HTTP 方法分布、平均耗时。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolGetRequestStats,
    ),
    McpToolDefinition(
      name: 'get_domain_summary',
      description: '按域名分组汇总抓包数据：请求数、接口路径去重列表。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'domain': {'type': 'string', 'description': '可选，只查看指定域名'},
        },
      },
      handler: toolGetDomainSummary,
    ),

    // ---------------- 历史记录 ----------------
    McpToolDefinition(
      name: 'get_histories',
      description: '列出所有保存的历史抓包会话（非实时，仅为已持久化的历史记录）。返回会话名称、请求数、大小、时间。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolGetHistories,
    ),

    // ---------------- 断点管理 ----------------
    McpToolDefinition(
      name: 'list_breakpoints',
      description: '列出当前所有断点拦截规则。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolListBreakpoints,
    ),
    McpToolDefinition(
      name: 'add_breakpoint',
      description: '新增断点拦截规则（按 URL 正则匹配，可拦截请求/响应阶段）。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': 'URL 正则表达式'},
          'name': {'type': 'string', 'description': '规则名称（可选）'},
          'interceptRequest': {'type': 'boolean', 'description': '拦截请求阶段，默认 true'},
          'interceptResponse': {'type': 'boolean', 'description': '拦截响应阶段'},
          'method': {'type': 'string', 'description': '仅匹配指定方法'},
        },
        'required': ['url'],
      },
      handler: toolAddBreakpoint,
    ),
    McpToolDefinition(
      name: 'remove_breakpoint',
      description: '删除指定断点规则。index 从 list_breakpoints 获取。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer', 'description': '规则序号'},
        },
        'required': ['index'],
      },
      handler: toolRemoveBreakpoint,
    ),

    // ---------------- 代理状态 ----------------
    McpToolDefinition(
      name: 'get_proxy_status',
      description: '获取代理服务状态与配置（端口、SSL 抓包、代理端口范围等）。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolGetProxyStatus,
    ),
  ];
}

// ============ 工具实现 ============

/// 兼容 String 数字与 num 的整数解析
int _toInt(Map<String, dynamic> args, String key, int fallback) {
  final v = args[key];
  if (v == null) return fallback;
  if (v is num) return v.toInt();
  if (v is String) {
    final parsed = int.tryParse(v);
    return parsed ?? fallback;
  }
  return fallback;
}

Map<String, dynamic> _ok(dynamic data) => {'ok': true, 'data': data};
Map<String, dynamic> _err(String msg) => {'ok': false, 'error': msg};

/// 请求摘要（不含响应体）
Map<String, dynamic> _reqSummary(HttpRequest r) {
  final resp = r.response;
  return {
    'method': r.method.name,
    'url': r.requestUrl,
    'path': r.pathAndQuery,
    'host': r.hostAndPort?.host,
    'statusCode': resp?.status.code,
    'requestTime': r.requestTime.millisecondsSinceEpoch,
    'requestLength': r.headers.contentLength,
    'responseLength': resp?.contentLength,
  };
}

/// 请求完整详情
Map<String, dynamic> _reqDetail(HttpRequest r) {
  final resp = r.response;
  return {
    'method': r.method.name,
    'url': r.requestUrl,
    'path': r.pathAndQuery,
    'requestHeaders': r.headers.toJson(),
    'requestBody': r.body == null ? null : utf8.decode(r.body!, allowMalformed: true),
    'response': resp == null
        ? null
        : {
            'statusCode': resp.status.code,
            'statusReason': resp.status.reasonPhrase,
            'headers': resp.headers.toJson(),
            'body': resp.body == null ? null : utf8.decode(resp.body!, allowMalformed: true),
          },
    'requestTime': r.requestTime.millisecondsSinceEpoch,
  };
}

/// 读取全部历史请求
Future<List<HttpRequest>> _allRequests() async {
  final results = <HttpRequest>[];

  // 实时抓包 buffer（当前这次启动抓到的请求）
  try {
    results.addAll(MobileApp.container.source);
  } catch (_) {}

  // 兜底：历史持久化请求（可能包含实时未覆盖的）
  try {
    final storage = await HistoryStorage.instance;
    for (final h in storage.histories) {
      try {
        final reqs = await storage.getRequests(h);
        results.addAll(reqs);
      } catch (_) {}
    }
  } catch (_) {}

  return results;
}

// ---- get_request_list ----
Future<Map<String, dynamic>> toolGetRequestList(Map<String, dynamic> args) async {
  final reqs = await _allRequests();
  final domain = args['domain'] as String?;
  final method = args['method'] as String?;
  final keyword = args['keyword'] as String?;
  final limit = _toInt(args, 'limit', 50);
  final offset = _toInt(args, 'offset', 0);

  var list = reqs.map(_reqSummary).toList();
  if (domain != null && domain.isNotEmpty) {
    list = list.where((e) => (e['host'] as String? ?? '').contains(domain)).toList();
  }
  if (method != null && method.isNotEmpty) {
    list = list.where((e) => e['method'] == method.toUpperCase()).toList();
  }
  if (keyword != null && keyword.isNotEmpty) {
    list = list.where((e) => (e['url'] as String? ?? '').contains(keyword)).toList();
  }
  final total = list.length;
  final paged = offset >= list.length
      ? <Map<String, dynamic>>[]
      : list.sublist(offset, (offset + limit) > list.length ? list.length : offset + limit);
  return _ok({'total': total, 'requests': paged});
}

// ---- get_request_detail ----
Future<Map<String, dynamic>> toolGetRequestDetail(Map<String, dynamic> args) async {
  final index = _toInt(args, 'index', -1);
  final reqs = await _allRequests();
  if (index < 0 || index >= reqs.length) return _err('index out of range');
  return _ok(_reqDetail(reqs[index]));
}

// ---- search_requests ----
Future<Map<String, dynamic>> toolSearchRequests(Map<String, dynamic> args) async {
  final urlKw = args['urlKeyword'] as String?;
  final bodyKw = args['bodyKeyword'] as String?;
  final limit = _toInt(args, 'limit', 50);
  final reqs = await _allRequests();
  final results = <Map<String, dynamic>>[];
  for (final r in reqs) {
    final detail = _reqDetail(r);
    var match = true;
    if (urlKw != null && urlKw.isNotEmpty && !(detail['url'] as String).contains(urlKw)) {
      match = false;
    }
    if (bodyKw != null && bodyKw.isNotEmpty) {
      final joint = '${detail['requestBody']}${detail['response']?['body']}'.toLowerCase();
      if (!joint.contains(bodyKw.toLowerCase())) match = false;
    }
    if (match) {
      results.add(detail);
      if (results.length >= limit) break;
    }
  }
  return _ok({'matches': results});
}

// ---- get_request_stats ----
Future<Map<String, dynamic>> toolGetRequestStats(Map<String, dynamic> args) async {
  final reqs = await _allRequests();
  final total = reqs.length;
  final domainMap = <String, int>{};
  final statusMap = <String, int>{};
  final methodMap = <String, int>{};
  var totalCostMs = 0;

  for (final r in reqs) {
    final host = r.hostAndPort?.host ?? '-';
    domainMap[host] = (domainMap[host] ?? 0) + 1;
    final sc = r.response?.status.code;
    statusMap['${sc ?? 'n/a'}'] = (statusMap['${sc ?? 'n/a'}'] ?? 0) + 1;
    methodMap[r.method.name] = (methodMap[r.method.name] ?? 0) + 1;
    final respTime = r.response?.responseTime ?? r.requestTime;
    totalCostMs += respTime.difference(r.requestTime).inMilliseconds;
  }

  final topDomain = domainMap.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

  return _ok({
    'total': total,
    'avgCostMs': total == 0 ? 0 : (totalCostMs / total).round(),
    'domains': topDomain.take(10).map((e) => {'domain': e.key, 'count': e.value}).toList(),
    'statusCodes': statusMap,
    'methods': methodMap,
  });
}

// ---- get_domain_summary ----
Future<Map<String, dynamic>> toolGetDomainSummary(Map<String, dynamic> args) async {
  final reqs = await _allRequests();
  final domain = args['domain'] as String?;
  final byDomain = <String, List<Map<String, dynamic>>>{};
  for (final r in reqs) {
    final host = r.hostAndPort?.host ?? '';
    if (domain != null && domain.isNotEmpty && !host.contains(domain)) continue;
    byDomain.putIfAbsent(host, () => []).add(_reqSummary(r));
  }
  final result = byDomain.entries.map((e) {
    final paths = e.value.map((s) => s['path'] as String).toSet().toList();
    return {'domain': e.key, 'count': e.value.length, 'paths': paths.take(50).toList()};
  }).toList();
  return _ok(result);
}

// ---- list_breakpoints ----
Future<Map<String, dynamic>> toolListBreakpoints(Map<String, dynamic> args) async {
  final m = await RequestBreakpointManager.instance;
  return _ok(m.list.map((e) => e.toJson()).toList());
}

// ---- add_breakpoint ----
Future<Map<String, dynamic>> toolAddBreakpoint(Map<String, dynamic> args) async {
  final m = await RequestBreakpointManager.instance;
  final methodStr = args['method'] as String?;
  HttpMethod? method;
  if (methodStr != null && methodStr.isNotEmpty) {
    try {
      method = HttpMethod.valueOf(methodStr);
    } catch (_) {
      method = null;
    }
  }
  final rule = RequestBreakpointRule(
    name: args['name'] as String? ?? 'mcp-breakpoint',
    url: args['url'] as String? ?? '',
    interceptRequest: args['interceptRequest'] as bool? ?? true,
    interceptResponse: args['interceptResponse'] as bool? ?? false,
    method: method,
  );
  m.add(rule);
  await m.save();
  return _ok('breakpoint added');
}

// ---- remove_breakpoint ----
Future<Map<String, dynamic>> toolRemoveBreakpoint(Map<String, dynamic> args) async {
  final m = await RequestBreakpointManager.instance;
  final index = _toInt(args, 'index', -1);
  if (index < 0 || index >= m.list.length) return _err('index out of range');
  final rule = m.list[index];
  m.remove(rule);
  await m.save();
  return _ok('removed');
}

// ---- get_histories ----
Future<Map<String, dynamic>> toolGetHistories(Map<String, dynamic> args) async {
  try {
    final storage = await HistoryStorage.instance;
    final list = storage.histories.map((h) => {
          'name': h.name,
          'path': h.path,
          'requestCount': h.requestLength,
          'fileSize': h.size,
          'createTime': h.createTime.millisecondsSinceEpoch,
        }).toList();
    return _ok({'total': list.length, 'histories': list});
  } catch (e) {
    return _err('read histories failed: ${e.toString()}');
  }
}

// ---- get_proxy_status ----
Future<Map<String, dynamic>> toolGetProxyStatus(Map<String, dynamic> args) async {
  final conf = await Configuration.instance;
  return _ok({
    'port': conf.port,
    'enableSsl': conf.enableSsl,
    'enableSocks5': conf.enableSocks5,
    'enabledHttp2': conf.enabledHttp2,
    'enableSystemProxy': conf.enableSystemProxy,
    'proxyPassDomains': conf.proxyPassDomains,
  });
}
