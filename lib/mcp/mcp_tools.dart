import 'dart:convert';
import 'dart:io';

import 'package:proxypin/native/installed_apps.dart';
import 'package:proxypin/native/vpn.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/manager/hosts_manager.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/components/manager/request_breakpoint_manager.dart';
import 'package:proxypin/network/components/manager/request_map_manager.dart';
import 'package:proxypin/network/components/manager/network_condition_manager.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/storage/path.dart';
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
    McpToolDefinition(
      name: 'get_history_requests',
      description: '查看指定历史会话的请求列表。传 name（会话名）或 index（会话序号）定位。detail=true 可返回每条的完整数据（请求头/体/响应）。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '历史会话名称（来自 get_histories）'},
          'index': {'type': 'integer', 'description': '历史会话序号（0 开始）'},
          'detail': {'type': 'boolean', 'description': '是否返回完整数据（请求头/请求体/响应头/响应体），默认 false 仅摘要'},
        },
      },
      handler: toolGetHistoryRequests,
    ),
    McpToolDefinition(
      name: 'get_history_request_detail',
      description: '查看某个历史会话中单条请求的完整数据（请求头、请求体、响应头、响应体）。需传会话 name/index 和请求序号 requestIndex。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '历史会话名称（来自 get_histories）'},
          'index': {'type': 'integer', 'description': '历史会话序号（0 开始），与 name 二选一'},
          'requestIndex': {'type': 'integer', 'description': '会话内请求序号（0 开始）'},
        },
        'required': ['requestIndex'],
      },
      handler: toolGetHistoryRequestDetail,
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

    // ---------------- 抓包开关 ----------------
    McpToolDefinition(
      name: 'start_capture',
      description: '启动抓包（启动代理服务器）。若需按应用过滤请先设置白名单并开启 VPN。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolStartCapture,
    ),
    McpToolDefinition(
      name: 'stop_capture',
      description: '停止抓包（停止代理服务器）。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolStopCapture,
    ),
    McpToolDefinition(
      name: 'get_capture_status',
      description: '获取当前抓包/代理/VPN 运行状态。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolGetCaptureStatus,
    ),

    // ---------------- 应用白名单 ----------------
    McpToolDefinition(
      name: 'list_installed_apps',
      description: '列出设备上已安装的应用（名称/包名），用于选择要抓包的应用。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'keyword': {'type': 'string', 'description': '按包名前缀过滤'},
          'includeSystem': {'type': 'boolean', 'description': '是否包含系统应用'},
          'limit': {'type': 'integer', 'description': '最大条数，默认 100'},
        },
      },
      handler: toolListInstalledApps,
    ),
    McpToolDefinition(
      name: 'get_app_whitelist',
      description: '获取当前抓包应用白名单（仅这些应用走代理抓包）。返回白名单开关状态和包名列表。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolGetAppWhitelist,
    ),
    McpToolDefinition(
      name: 'set_app_whitelist',
      description: '设置抓包应用白名单（仅指定包名的应用走代理抓包）。设置 appPackages 会自动开启白名单开关；用 enable:false 可关闭（改回抓全部应用）。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'appPackages': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '要抓包的应用包名列表，例如 ["com.example.app"]；设置后自动开启白名单开关',
          },
          'enable': {'type': 'boolean', 'description': '白名单开关，true=启用过滤，false=关闭过滤抓全部应用'},
        },
      },
      handler: toolSetAppWhitelist,
    ),

    // ---------------- VPN 模式 ----------------
    McpToolDefinition(
      name: 'start_vpn',
      description: '启动本地 VPN 抓包模式（按应用过滤抓包需要 VPN 模式）。首次需系统授权 VPN 连接。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolStartVpn,
    ),
    McpToolDefinition(
      name: 'stop_vpn',
      description: '停止 VPN 抓包模式。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolStopVpn,
    ),

    // ---------------- 屏蔽规则 ----------------
    McpToolDefinition(
      name: 'list_block_rules',
      description: '列出当前所有请求屏蔽规则。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolListBlockRules,
    ),
    McpToolDefinition(
      name: 'add_block_rule',
      description: '新增请求屏蔽规则（按 URL 匹配，可选屏蔽请求或响应）。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': 'URL 匹配模式（支持通配符），如 *.ads.example.com*'},
          'type': {'type': 'string', 'description': '屏蔽类型：blockRequest=屏蔽请求，blockResponse=屏蔽响应', 'enum': ['blockRequest', 'blockResponse']},
          'enabled': {'type': 'boolean', 'description': '是否启用，默认 true'},
        },
        'required': ['url'],
      },
      handler: toolAddBlockRule,
    ),
    McpToolDefinition(
      name: 'remove_block_rule',
      description: '删除指定屏蔽规则。index 从 list_block_rules 获取。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer', 'description': '规则序号'},
        },
        'required': ['index'],
      },
      handler: toolRemoveBlockRule,
    ),

    // ---------------- Hosts 劫持 ----------------
    McpToolDefinition(
      name: 'list_hosts',
      description: '列出当前所有 Hosts 劫持规则。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolListHosts,
    ),
    McpToolDefinition(
      name: 'add_host',
      description: '新增 Hosts 劫持规则（域名指向指定 IP）。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'host': {'type': 'string', 'description': '要劫持的域名'},
          'toAddress': {'type': 'string', 'description': '指向的 IP 地址'},
          'enabled': {'type': 'boolean', 'description': '是否启用，默认 true'},
        },
        'required': ['host', 'toAddress'],
      },
      handler: toolAddHost,
    ),
    McpToolDefinition(
      name: 'remove_host',
      description: '删除指定 Hosts 劫持规则。index 从 list_hosts 获取。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer', 'description': '规则序号'},
        },
        'required': ['index'],
      },
      handler: toolRemoveHost,
    ),

    // ---------------- URL 映射 ----------------
    McpToolDefinition(
      name: 'list_map_rules',
      description: '列出当前所有 URL 映射规则（把请求映射到本地响应或脚本）。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolListMapRules,
    ),
    McpToolDefinition(
      name: 'add_map_rule',
      description: '新增 URL 映射规则。type=local 用本地 body/statusCode 响应；type=script 用脚本拦截。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': '要匹配的 URL 模式'},
          'type': {'type': 'string', 'description': '映射类型：local=本地响应，script=脚本', 'enum': ['local', 'script']},
          'name': {'type': 'string', 'description': '规则名称（可选）'},
          'body': {'type': 'string', 'description': '本地响应的 body 内容（type=local 时）'},
          'statusCode': {'type': 'integer', 'description': '本地响应状态码（type=local 时）'},
          'script': {'type': 'string', 'description': '脚本内容（type=script 时）'},
        },
        'required': ['url'],
      },
      handler: toolAddMapRule,
    ),
    McpToolDefinition(
      name: 'remove_map_rule',
      description: '删除指定 URL 映射规则。index 从 list_map_rules 获取。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer', 'description': '规则序号'},
        },
        'required': ['index'],
      },
      handler: toolRemoveMapRule,
    ),

    // ---------------- 弱网模拟 ----------------
    McpToolDefinition(
      name: 'list_weak_network',
      description: '列出当前所有弱网模拟规则。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolListWeakNetwork,
    ),
    McpToolDefinition(
      name: 'add_weak_network',
      description: '新增弱网模拟规则（对指定 URL 应用网络档位）。profile 可选 weak/slow/g2/g3/g4/g5/wifi。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': '匹配 URL 模式（支持通配符）'},
          'profile': {'type': 'string', 'description': '网络档位：weak/slow/g2/g3/g4/g5/wifi', 'enum': ['weak', 'slow', 'g2', 'g3', 'g4', 'g5', 'wifi']},
          'enabled': {'type': 'boolean', 'description': '是否启用，默认 true'},
        },
        'required': ['url'],
      },
      handler: toolAddWeakNetwork,
    ),
    McpToolDefinition(
      name: 'remove_weak_network',
      description: '删除指定弱网模拟规则。index 从 list_weak_network 获取。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer', 'description': '规则序号'},
        },
        'required': ['index'],
      },
      handler: toolRemoveWeakNetwork,
    ),

    // ---------------- JS 脚本 ----------------
    McpToolDefinition(
      name: 'list_scripts',
      description: '列出当前所有 JS 拦截脚本。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolListScripts,
    ),
    McpToolDefinition(
      name: 'create_or_update_script',
      description: '创建或更新 JS 拦截脚本。urls 为匹配 URL 列表（逗号分隔或数组）。传 index 则更新已有脚本。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '脚本名称'},
          'urls': {'type': 'string', 'description': '匹配的 URL 模式，多个用逗号分隔'},
          'script': {'type': 'string', 'description': 'JavaScript 脚本代码'},
          'index': {'type': 'integer', 'description': '要更新的脚本序号（不填则新增）'},
        },
        'required': ['name', 'urls', 'script'],
      },
      handler: toolCreateOrUpdateScript,
    ),
    McpToolDefinition(
      name: 'remove_script',
      description: '删除指定脚本。index 从 list_scripts 获取。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer', 'description': '脚本序号'},
        },
        'required': ['index'],
      },
      handler: toolRemoveScript,
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
/// 读取实时抓包请求（仅当前抓包容器，与 App 请求列表一致）。
Future<List<HttpRequest>> _allRequests() async {
  return List.of(MobileApp.container.source);
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

// ---- get_history_requests ----
Future<Map<String, dynamic>> toolGetHistoryRequests(Map<String, dynamic> args) async {
  try {
    final storage = await HistoryStorage.instance;
    final name = args['name'] as String?;
    final index = _toInt(args, 'index', -1);

    // 定位目标历史项（按 name 精确匹配，或按 index）
    HistoryItem? target;
    if (name != null && name.isNotEmpty) {
      for (final h in storage.histories) {
        if (h.name == name) {
          target = h;
          break;
        }
      }
    } else if (index >= 0 && index < storage.histories.length) {
      target = storage.histories[index];
    }

    if (target == null) {
      return _err('history not found (use name or index)');
    }

    final reqs = await storage.getRequests(target);
    final detail = args['detail'] as bool? ?? false;
    final list = detail ? reqs.map(_reqDetail).toList() : reqs.map(_reqSummary).toList();
    return _ok({'historyName': target.name, 'total': list.length, 'requests': list});
  } catch (e) {
    return _err('read history requests failed: ${e.toString()}');
  }
}

// ---- get_history_request_detail ----
Future<Map<String, dynamic>> toolGetHistoryRequestDetail(Map<String, dynamic> args) async {
  try {
    final storage = await HistoryStorage.instance;
    final name = args['name'] as String?;
    final index = _toInt(args, 'index', -1);
    final reqIndex = _toInt(args, 'requestIndex', -1);

    HistoryItem? target;
    if (name != null && name.isNotEmpty) {
      for (final h in storage.histories) {
        if (h.name == name) {
          target = h;
          break;
        }
      }
    } else if (index >= 0 && index < storage.histories.length) {
      target = storage.histories[index];
    }

    if (target == null) {
      return _err('history not found (use name or index)');
    }

    final reqs = await storage.getRequests(target);
    if (reqIndex < 0 || reqIndex >= reqs.length) {
      return _err('request index out of range');
    }
    return _ok(_reqDetail(reqs[reqIndex]));
  } catch (e) {
    return _err('read history request detail failed: ${e.toString()}');
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

// ---- start_capture ----
Future<Map<String, dynamic>> toolStartCapture(Map<String, dynamic> args) async {
  final server = ProxyServer.current;
  if (server == null) {
    return _err('ProxyServer not initialized');
  }
  try {
    // 1. 启动代理服务器（若未运行）
    if (!server.isRunning) {
      await server.start();
    }
    // 2. 启动本地 VPN，将手机 app 流量重定向到代理（首次需系统 VPN 授权）
    if (!Vpn.isVpnStarted) {
      Vpn.startVpn('127.0.0.1', server.port, server.configuration);
    }
    return _ok('capture started (proxy + vpn)');
  } catch (e) {
    return _err('start capture failed: ${e.toString()}');
  }
}

// ---- stop_capture ----
Future<Map<String, dynamic>> toolStopCapture(Map<String, dynamic> args) async {
  final server = ProxyServer.current;
  if (server == null) {
    return _err('ProxyServer not initialized');
  }
  try {
    // 停止 VPN
    if (Vpn.isVpnStarted) {
      Vpn.stopVpn();
    }
    // 停止代理服务器
    if (server.isRunning) {
      await server.stop();
    }
    return _ok('capture stopped (proxy + vpn)');
  } catch (e) {
    return _err('stop capture failed: ${e.toString()}');
  }
}

// ---- get_capture_status ----
Future<Map<String, dynamic>> toolGetCaptureStatus(Map<String, dynamic> args) async {
  final server = ProxyServer.current;
  final conf = await Configuration.instance;
  return _ok({
    'serverRunning': server?.isRunning ?? false,
    'vpnRunning': Vpn.isVpnStarted,
    'port': conf.port,
    'appWhitelistEnabled': conf.appWhitelistEnabled,
    'appWhitelistCount': conf.appWhitelist.length,
  });
}

// ---- list_installed_apps ----
Future<Map<String, dynamic>> toolListInstalledApps(Map<String, dynamic> args) async {
  try {
    final keyword = args['keyword'] as String?;
    final includeSystem = args['includeSystem'] as bool? ?? false;
    final limit = _toInt(args, 'limit', 100);
    final apps = await InstalledApps.getInstalledApps(false,
        packageNamePrefix: keyword, includeSystemApps: includeSystem);
    final list = apps
        .take(limit)
        .map((a) => {'name': a.name, 'packageName': a.packageName, 'versionName': a.versionName, 'inValid': a.inValid})
        .toList();
    return _ok({'total': list.length, 'apps': list});
  } catch (e) {
    return _err('list apps failed: ${e.toString()}');
  }
}

// ---- get_app_whitelist ----
Future<Map<String, dynamic>> toolGetAppWhitelist(Map<String, dynamic> args) async {
  final conf = await Configuration.instance;
  return _ok({
    'enabled': conf.appWhitelistEnabled,
    'appPackages': conf.appWhitelist,
  });
}

// ---- set_app_whitelist ----
Future<Map<String, dynamic>> toolSetAppWhitelist(Map<String, dynamic> args) async {
  final conf = await Configuration.instance;
  final packages = args['appPackages'];
  if (packages is List) {
    conf.appWhitelist = packages.map((e) => e.toString()).toList();
    // 设置应用列表时，默认开启白名单开关（否则不生效抓不到目标应用）
    conf.appWhitelistEnabled = true;
  }
  // 显式 enable 参数可覆盖开关状态（false = 关闭白名单过滤，抓所有应用）
  if (args['enable'] != null) {
    conf.appWhitelistEnabled = args['enable'] as bool;
  }
  await conf.flushConfig();
  return _ok({'enabled': conf.appWhitelistEnabled, 'appPackages': conf.appWhitelist});
}

// ---- start_vpn ----
Future<Map<String, dynamic>> toolStartVpn(Map<String, dynamic> args) async {
  final server = ProxyServer.current;
  final conf = await Configuration.instance;
  if (server == null) {
    return _err('ProxyServer not initialized');
  }
  try {
    // 确保代理先启动，再用代理配置启动 VPN
    if (server.server == null) {
      await server.start();
    }
    Vpn.startVpn('127.0.0.1', conf.port, conf);
    return _ok('vpn started');
  } catch (e) {
    return _err('start vpn failed: ${e.toString()}');
  }
}

// ---- stop_vpn ----
Future<Map<String, dynamic>> toolStopVpn(Map<String, dynamic> args) async {
  try {
    Vpn.stopVpn();
    return _ok('vpn stopped');
  } catch (e) {
    return _err('stop vpn failed: ${e.toString()}');
  }
}

// ---- list_block_rules ----
Future<Map<String, dynamic>> toolListBlockRules(Map<String, dynamic> args) async {
  try {
    final m = await RequestBlockManager.instance;
    final list = m.list.map((e) => {'enabled': e.enabled, 'url': e.url, 'type': e.type.name}).toList();
    return _ok({'total': list.length, 'rules': list});
  } catch (e) {
    return _err('list block rules failed: ${e.toString()}');
  }
}

// ---- add_block_rule ----
Future<Map<String, dynamic>> toolAddBlockRule(Map<String, dynamic> args) async {
  try {
    final m = await RequestBlockManager.instance;
    final url = args['url'] as String? ?? '';
    final typeStr = args['type'] as String? ?? 'blockRequest';
    final enabled = args['enabled'] as bool? ?? true;
    BlockType type;
    try {
      type = BlockType.values.firstWhere((e) => e.name == typeStr);
    } catch (_) {
      type = BlockType.blockRequest;
    }
    m.addBlockRequest(RequestBlockItem(enabled, url, type));
    return _ok('block rule added');
  } catch (e) {
    return _err('add block rule failed: ${e.toString()}');
  }
}

// ---- remove_block_rule ----
Future<Map<String, dynamic>> toolRemoveBlockRule(Map<String, dynamic> args) async {
  try {
    final m = await RequestBlockManager.instance;
    final index = _toInt(args, 'index', -1);
    if (index < 0 || index >= m.list.length) return _err('index out of range');
    m.removeBlockRequest(index);
    return _ok('block rule removed');
  } catch (e) {
    return _err('remove block rule failed: ${e.toString()}');
  }
}

// ---- list_hosts ----
Future<Map<String, dynamic>> toolListHosts(Map<String, dynamic> args) async {
  try {
    final m = await HostsManager.instance;
    final list = m.list
        .map((e) => {'enabled': e.enabled, 'host': e.host, 'toAddress': e.toAddress})
        .toList();
    return _ok({'total': list.length, 'hosts': list});
  } catch (e) {
    return _err('list hosts failed: ${e.toString()}');
  }
}

// ---- add_host ----
Future<Map<String, dynamic>> toolAddHost(Map<String, dynamic> args) async {
  try {
    final m = await HostsManager.instance;
    final host = args['host'] as String? ?? '';
    final toAddress = args['toAddress'] as String?;
    final enabled = args['enabled'] as bool? ?? true;
    final item = HostsItem(host: host, toAddress: toAddress, enabled: enabled);
    await m.addHosts(item);
    return _ok('host added');
  } catch (e) {
    return _err('add host failed: ${e.toString()}');
  }
}

// ---- remove_host ----
Future<Map<String, dynamic>> toolRemoveHost(Map<String, dynamic> args) async {
  try {
    final m = await HostsManager.instance;
    final index = _toInt(args, 'index', -1);
    if (index < 0 || index >= m.list.length) return _err('index out of range');
    final item = m.list[index];
    await m.removeHosts([item]);
    return _ok('host removed');
  } catch (e) {
    return _err('remove host failed: ${e.toString()}');
  }
}

// ---- list_map_rules ----
Future<Map<String, dynamic>> toolListMapRules(Map<String, dynamic> args) async {
  try {
    final m = await RequestMapManager.instance;
    final list = m.rules
        .map((r) => {'enabled': r.enabled, 'name': r.name, 'url': r.url, 'type': r.type.name})
        .toList();
    return _ok({'total': list.length, 'rules': list});
  } catch (e) {
    return _err('list map rules failed: ${e.toString()}');
  }
}

// ---- add_map_rule ----
Future<Map<String, dynamic>> toolAddMapRule(Map<String, dynamic> args) async {
  try {
    final m = await RequestMapManager.instance;
    final url = args['url'] as String? ?? '';
    final typeStr = args['type'] as String? ?? 'local';
    final name = args['name'] as String?;
    RequestMapType type;
    try {
      type = RequestMapType.values.firstWhere((e) => e.name == typeStr);
    } catch (_) {
      type = RequestMapType.local;
    }
    final rule = RequestMapRule(name: name, url: url, type: type);
    final item = RequestMapItem(
      body: args['body'] as String?,
      statusCode: (args['statusCode'] as num?)?.toInt(),
      script: args['script'] as String?,
    );
    await m.addRule(rule, item);
    return _ok('map rule added');
  } catch (e) {
    return _err('add map rule failed: ${e.toString()}');
  }
}

// ---- remove_map_rule ----
Future<Map<String, dynamic>> toolRemoveMapRule(Map<String, dynamic> args) async {
  try {
    final m = await RequestMapManager.instance;
    final index = _toInt(args, 'index', -1);
    if (index < 0 || index >= m.rules.length) return _err('index out of range');
    m.rules.removeAt(index);
    await m.flushConfig();
    return _ok('map rule removed');
  } catch (e) {
    return _err('remove map rule failed: ${e.toString()}');
  }
}

// ---- list_weak_network ----
Future<Map<String, dynamic>> toolListWeakNetwork(Map<String, dynamic> args) async {
  try {
    final m = await NetworkConditionManager.instance;
    final list = m.rules
        .map((r) => {'enabled': r.enabled, 'url': r.url, 'profileId': r.profileId})
        .toList();
    return _ok({'enabled': m.enabled, 'total': list.length, 'rules': list});
  } catch (e) {
    return _err('list weak network failed: ${e.toString()}');
  }
}

// ---- add_weak_network ----
Future<Map<String, dynamic>> toolAddWeakNetwork(Map<String, dynamic> args) async {
  try {
    final m = await NetworkConditionManager.instance;
    final url = args['url'] as String? ?? '';
    final profile = args['profile'] as String? ?? 'g4';
    final enabled = args['enabled'] as bool? ?? true;
    final rule = NetworkConditionRule(enabled: enabled, url: url, profileId: profile);
    m.rules.add(rule);
    await m.flushConfig();
    return _ok('weak network rule added');
  } catch (e) {
    return _err('add weak network failed: ${e.toString()}');
  }
}

// ---- remove_weak_network ----
Future<Map<String, dynamic>> toolRemoveWeakNetwork(Map<String, dynamic> args) async {
  try {
    final m = await NetworkConditionManager.instance;
    final index = _toInt(args, 'index', -1);
    if (index < 0 || index >= m.rules.length) return _err('index out of range');
    m.rules.removeAt(index);
    await m.flushConfig();
    return _ok('weak network rule removed');
  } catch (e) {
    return _err('remove weak network failed: ${e.toString()}');
  }
}

// ---- list_scripts ----
Future<Map<String, dynamic>> toolListScripts(Map<String, dynamic> args) async {
  try {
    final m = await ScriptManager.instance;
    final list = m.list
        .map((e) => {'name': e.name, 'urls': e.urls, 'enabled': e.enabled, 'scriptPath': e.scriptPath})
        .toList();
    return _ok({'total': list.length, 'scripts': list});
  } catch (e) {
    return _err('list scripts failed: ${e.toString()}');
  }
}

// ---- create_or_update_script ----
Future<Map<String, dynamic>> toolCreateOrUpdateScript(Map<String, dynamic> args) async {
  try {
    final m = await ScriptManager.instance;
    final name = args['name'] as String? ?? '';
    final urlsRaw = args['urls'];
    final script = args['script'] as String?;
    final index = _toInt(args, 'index', -1);

    List<String> urls;
    if (urlsRaw is String) {
      urls = urlsRaw.contains(',')
          ? urlsRaw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList()
          : [urlsRaw];
    } else if (urlsRaw is List) {
      urls = urlsRaw.map((e) => e.toString()).toList();
    } else {
      urls = <String>[];
    }

    if (index >= 0 && index < m.list.length) {
      // 更新已有脚本
      final existing = m.list[index];
      existing.name = name;
      existing.urls = urls;
      if (script != null && script.isNotEmpty && existing.scriptPath != null) {
        final home = await Paths.homePath();
        await File('$home${existing.scriptPath}').writeAsString(script);
      }
      return _ok('script updated');
    }

    // 新增
    final item = ScriptItem(true, name, urls);
    await m.addScript(item, script);
    return _ok('script created');
  } catch (e) {
    return _err('create/update script failed: ${e.toString()}');
  }
}

// ---- remove_script ----
Future<Map<String, dynamic>> toolRemoveScript(Map<String, dynamic> args) async {
  try {
    final m = await ScriptManager.instance;
    final index = _toInt(args, 'index', -1);
    if (index < 0 || index >= m.list.length) return _err('index out of range');
    await m.removeScript(index);
    return _ok('script removed');
  } catch (e) {
    return _err('remove script failed: ${e.toString()}');
  }
}
