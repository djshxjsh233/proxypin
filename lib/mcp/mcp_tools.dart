import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:proxypin/native/installed_apps.dart';
import 'package:proxypin/native/vpn.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/manager/hosts_manager.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/components/manager/request_breakpoint_manager.dart';
import 'package:proxypin/network/components/manager/request_map_manager.dart';
import 'package:proxypin/network/components/manager/network_condition_manager.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/request_crypto_manager.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/utils/aes.dart';
import 'package:proxypin/utils/crypto_body_decoder.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/components/request_breakpoint.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/network/http/http_client.dart';
import 'package:proxypin/network/channel/host_port.dart';
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

    // ---------------- 断点放行/中止 ----------------
    McpToolDefinition(
      name: 'list_pending_intercepts',
      description: '列出当前挂起中的断点（请求/响应），返回 requestId 与摘要。用于配合 release_intercept / abort_intercepts 操作。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolListPendingIntercepts,
    ),
    McpToolDefinition(
      name: 'release_intercept',
      description: '放行一个挂起的断点。requestId 从 list_pending_intercepts 获取。可选提供 method/uri/headers/body 覆盖原值（空则原样放行）。返回 true 表示成功。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'requestId': {'type': 'string', 'description': '挂起断点的 requestId（来自 list_pending_intercepts）'},
          'method': {'type': 'string', 'description': '可选：覆盖请求方法'},
          'uri': {'type': 'string', 'description': '可选：覆盖请求 URL'},
          'headers': {'type': 'object', 'description': '可选：覆盖请求头（map，值转字符串）'},
          'body': {'type': 'string', 'description': '可选：覆盖请求体'},
        },
        'required': ['requestId'],
      },
      handler: toolReleaseIntercept,
    ),
    McpToolDefinition(
      name: 'abort_intercepts',
      description: '中止（丢弃）当前所有挂起的断点请求，使其不发出。返回被中止的数量。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolAbortIntercepts,
    ),

    // ---------------- 加解密 ----------------
    McpToolDefinition(
      name: 'list_crypto_rules',
      description: '列出所有请求加解密规则（含总开关状态）。配置规则后，抓包详情会自动解密匹配请求/响应体。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolListCryptoRules,
    ),
    McpToolDefinition(
      name: 'add_crypto_rule',
      description: '新增请求加解密规则。urlPattern 为正则；key 为 AES 密钥；mode=CBC/ECB；padding=PKCS7/ZeroPadding 等；keyLength=128/192/256；CBC 需 iv（或 ivSource=prefix 用密文前 N 字节作 IV）。field 可选：从 JSON body 中提取指定字段解密（如 data 或 items[0].value）。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'urlPattern': {'type': 'string', 'description': 'URL 正则匹配'},
          'name': {'type': 'string', 'description': '规则名称（可选）'},
          'key': {'type': 'string', 'description': 'AES 密钥'},
          'iv': {'type': 'string', 'description': 'CBC 模式的 IV'},
          'ivSource': {'type': 'string', 'description': 'IV 来源：manual=手动指定，prefix=密文前 N 字节', 'enum': ['manual', 'prefix']},
          'ivPrefixLength': {'type': 'integer', 'description': 'prefix 模式的 IV 长度，默认 16'},
          'mode': {'type': 'string', 'description': '加密模式：ECB 或 CBC，默认 ECB', 'enum': ['ECB', 'CBC']},
          'padding': {'type': 'string', 'description': '填充方式，默认 PKCS7'},
          'keyLength': {'type': 'integer', 'description': '密钥长度 128/192/256，默认 128'},
          'field': {'type': 'string', 'description': '可选：从 JSON body 提取该字段解密'},
          'enabled': {'type': 'boolean', 'description': '是否启用，默认 true'},
        },
        'required': ['urlPattern', 'key'],
      },
      handler: toolAddCryptoRule,
    ),
    McpToolDefinition(
      name: 'update_crypto_rule',
      description: '按 index 更新加解密规则。只更新传入的字段，其余保留。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer', 'description': '规则序号'},
          'urlPattern': {'type': 'string'},
          'name': {'type': 'string'},
          'key': {'type': 'string'},
          'iv': {'type': 'string'},
          'ivSource': {'type': 'string'},
          'ivPrefixLength': {'type': 'integer'},
          'mode': {'type': 'string'},
          'padding': {'type': 'string'},
          'keyLength': {'type': 'integer'},
          'field': {'type': 'string'},
          'enabled': {'type': 'boolean'},
        },
        'required': ['index'],
      },
      handler: toolUpdateCryptoRule,
    ),
    McpToolDefinition(
      name: 'remove_crypto_rule',
      description: '按 index 删除加解密规则。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer', 'description': '规则序号'},
        },
        'required': ['index'],
      },
      handler: toolRemoveCryptoRule,
    ),
    McpToolDefinition(
      name: 'set_crypto_enabled',
      description: '开启/关闭请求加解密总开关。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'enable': {'type': 'boolean', 'description': '是否启用加解密'},
        },
        'required': ['enable'],
      },
      handler: toolSetCryptoEnabled,
    ),
    McpToolDefinition(
      name: 'decrypt_body',
      description: '直接解密一段密文（不依赖规则）。body 可传 base64 密文或原始文本；key/iv/mode/padding/keyLength 指定 AES 参数；ivSource=prefix 时取密文前 N 字节作 IV。返回解密后的文本。分析签名/加密响应体利器。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'body': {'type': 'string', 'description': '密文：base64 字符串或原始文本'},
          'key': {'type': 'string', 'description': 'AES 密钥'},
          'iv': {'type': 'string', 'description': 'CBC 模式的 IV'},
          'ivSource': {'type': 'string', 'description': 'manual 或 prefix', 'enum': ['manual', 'prefix']},
          'ivPrefixLength': {'type': 'integer', 'description': 'prefix 模式 IV 长度，默认 16'},
          'mode': {'type': 'string', 'description': 'ECB 或 CBC，默认 ECB', 'enum': ['ECB', 'CBC']},
          'padding': {'type': 'string', 'description': '默认 PKCS7'},
          'keyLength': {'type': 'integer', 'description': '默认 128'},
        },
        'required': ['body', 'key'],
      },
      handler: toolDecryptBody,
    ),
    McpToolDefinition(
      name: 'encrypt_body',
      description: '用 AES 加密一段明文（与 decrypt_body 对称，用于验证加密算法/构造请求体）。body 为明文文本；key/iv/mode/padding/keyLength 指定 AES 参数；ivSource=prefix 时自动生成随机 IV 并前置到密文。返回 base64 与 hex 密文。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'body': {'type': 'string', 'description': '明文内容'},
          'key': {'type': 'string', 'description': 'AES 密钥'},
          'iv': {'type': 'string', 'description': 'CBC 模式的 IV'},
          'ivSource': {'type': 'string', 'description': 'manual 或 prefix（自动生成 IV 前置），默认 manual', 'enum': ['manual', 'prefix']},
          'ivPrefixLength': {'type': 'integer', 'description': 'prefix 模式 IV 长度，默认 16'},
          'mode': {'type': 'string', 'description': 'ECB 或 CBC，默认 ECB', 'enum': ['ECB', 'CBC']},
          'padding': {'type': 'string', 'description': '默认 PKCS7'},
          'keyLength': {'type': 'integer', 'description': '默认 128'},
        },
        'required': ['body', 'key'],
      },
      handler: toolEncryptBody,
    ),
    McpToolDefinition(
      name: 'detect_body_encoding',
      description: '自动检测一段 body 的编码/格式：base64、hex、JSON、gzip、URL编码、普通文本，并给出疑似 AES 密文特征（解码后长度是否 16 对齐等）。分析加密响应体/签名参数时先跑这个确定格式。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'body': {'type': 'string', 'description': '要检测的内容（base64/hex/文本均可）'},
        },
        'required': ['body'],
      },
      handler: toolDetectBodyEncoding,
    ),
    McpToolDefinition(
      name: 'analyze_signature',
      description: '分析一段签名/密文参数，识别可能算法：MD5(32hex)、SHA1(40hex)、SHA224(56hex)、SHA256(64hex)、base64、AES 密文特征等。还原接口 sign 参数时先跑这个缩小算法范围。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'value': {'type': 'string', 'description': '要分析的签名值（如 URL 里的 sig 参数）'},
        },
        'required': ['value'],
      },
      handler: toolAnalyzeSignature,
    ),
    McpToolDefinition(
      name: 'replay_request',
      description: '重放一个已抓包的请求（官方 proxyRequest 链路，走本地代理）。可覆盖 method/uri/headers/body 后重发，用于验证签名算法/改参测试。url 必填；未提供其他字段时按 url 发 GET。返回响应状态码、耗时、响应头与响应体(前2000字符)。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': '请求完整 URL'},
          'method': {'type': 'string', 'description': 'GET/POST/PUT/DELETE 等，默认 GET'},
          'headers': {'type': 'object', 'description': '可选：请求头（map，值转字符串）'},
          'body': {'type': 'string', 'description': '可选：请求体（POST/PUT 时）'},
          'timeoutSeconds': {'type': 'integer', 'description': '超时秒数，默认 15'},
        },
        'required': ['url'],
      },
      handler: toolReplayRequest,
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
    McpToolDefinition(
      name: 'set_weak_network_enabled',
      description: '开启/关闭弱网模拟总开关（影响所有弱网规则是否生效）。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'enable': {'type': 'boolean', 'description': '是否启用弱网模拟'},
        },
        'required': ['enable'],
      },
      handler: toolSetWeakNetworkEnabled,
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

    // ---------------- 请求重写 ----------------
    McpToolDefinition(
      name: 'list_rewrite_rules',
      description: '列出当前所有请求重写规则。',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: toolListRewriteRules,
    ),
    McpToolDefinition(
      name: 'add_rewrite_rule',
      description: '新增请求重写规则。ruleType: responseReplace=替换响应体, requestReplace=替换请求体, redirect=重定向, responseUpdate=修改响应, requestUpdate=修改请求。body/statusCode/headers/redirectUrl 按需填。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': '匹配的 URL 模式'},
          'ruleType': {
            'type': 'string',
            'description': '规则类型',
            'enum': ['responseReplace', 'requestReplace', 'redirect', 'responseUpdate', 'requestUpdate'],
          },
          'name': {'type': 'string', 'description': '规则名称（可选）'},
          'body': {'type': 'string', 'description': '替换的请求/响应体内容'},
          'statusCode': {'type': 'integer', 'description': '替换响应状态码（responseReplace 时）'},
          'headers': {'type': 'object', 'description': '替换的响应/请求头（键值对）'},
          'redirectUrl': {'type': 'string', 'description': '重定向目标 URL（redirect 类型必填）'},
        },
        'required': ['url', 'ruleType'],
      },
      handler: toolAddRewriteRule,
    ),
    McpToolDefinition(
      name: 'remove_rewrite_rule',
      description: '删除指定重写规则。index 从 list_rewrite_rules 获取。',
      inputSchema: {
        'type': 'object',
        'properties': {
          'index': {'type': 'integer', 'description': '规则序号'},
        },
        'required': ['index'],
      },
      handler: toolRemoveRewriteRule,
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
/// 安全 base64: body 必须是 0-255 的字节序列才编码; 历史 HAR 还原的 UTF-16 code units
/// (值 >255, 如中文 0x6210) 无法作为字节, 返回 null 避免抛 Not a byte value。
String? _safeBase64(List<int>? bytes) {
  if (bytes == null || bytes.isEmpty) return null;
  for (final b in bytes) {
    if (b < 0 || b > 255) return null;
  }
  try {
    return base64.encode(bytes);
  } catch (_) {
    return null;
  }
}

/// 尝试按加解密规则解密 body, 返回 (明文文本, 是否命中规则, 规则名)。
Future<(String?, bool, String?)> _tryDecryptBody(HttpMessage message) async {
  if (message.body == null || message.body!.isEmpty) return (null, false, null);
  try {
    final result = await CryptoBodyDecoder.maybeDecode(message);
    if (result != null && result.hasText) {
      return (result.text, true, result.rule?.name);
    }
  } catch (_) {}
  return (null, false, null);
}

/// WebSocket/SSE 帧摘要: 方向 + 类型 + 内容(文本直接给, 二进制给base64)
Map<String, dynamic> _frameSummary(WebSocketFrame f) {
  final type = switch (f.opcode) {
    0x01 => 'text',
    0x02 => 'binary',
    0x08 => 'close',
    0x09 => 'ping',
    0x0a => 'pong',
    _ => 'opcode:${f.opcode}',
  };
  final payload = f.opcode == 0x02
      ? 'base64:${base64.encode(f.payloadData)}'
      : f.payloadDataAsString;
  return {
    'dir': f.isFromClient ? 'request' : 'response',
    'type': type,
    'time': f.time.millisecondsSinceEpoch,
    'payload': payload.length > 2000 ? '${payload.substring(0, 2000)}...(共${payload.length}字符)' : payload,
  };
}

Future<Map<String, dynamic>> _reqDetail(HttpRequest r) async {
  final resp = r.response;
  // 请求/响应体: 用 getBodyString() 自动解压 gzip/br/deflate(与 App 显示一致),
  // 同时提供 bodyBase64 无损原始字节(供解密/签名分析; 非字节序列时为 null)。
  // 若配置了加解密规则且命中, 额外提供解密后的明文(decryptedText)与规则名。
  String? reqBodyText;
  String? reqBodyB64;
  String? reqDecrypted;
  bool reqDecryptedHit = false;
  String? reqDecryptedRule;
  if (r.body != null && r.body!.isNotEmpty) {
    reqBodyText = r.getBodyString();
    reqBodyB64 = _safeBase64(r.body);
    final dec = await _tryDecryptBody(r);
    reqDecrypted = dec.$1;
    reqDecryptedHit = dec.$2;
    reqDecryptedRule = dec.$3;
  }
  String? respBodyText;
  String? respBodyB64;
  String? respDecrypted;
  bool respDecryptedHit = false;
  String? respDecryptedRule;
  if (resp?.body != null && resp!.body!.isNotEmpty) {
    respBodyText = resp.getBodyString();
    respBodyB64 = _safeBase64(resp.body);
    final dec = await _tryDecryptBody(resp);
    respDecrypted = dec.$1;
    respDecryptedHit = dec.$2;
    respDecryptedRule = dec.$3;
  }
  return {
    'method': r.method.name,
    'url': r.requestUrl,
    'path': r.pathAndQuery,
    'requestHeaders': r.headers.toJson(),
    'requestBody': reqBodyText,
    'requestBodyBase64': reqBodyB64,
    'requestContentEncoding': r.headers.contentEncoding,
    if (reqDecryptedHit) 'requestDecryptedText': reqDecrypted,
    if (reqDecryptedHit) 'requestDecryptedRule': reqDecryptedRule,
    // WebSocket/SSE 帧消息(若有)
    if (r.messages.isNotEmpty) 'requestMessages': r.messages.map(_frameSummary).toList(),
    'response': resp == null
        ? null
        : {
            'statusCode': resp.status.code,
            'statusReason': resp.status.reasonPhrase,
            'headers': resp.headers.toJson(),
            'body': respBodyText,
            'bodyBase64': respBodyB64,
            'contentEncoding': resp.headers.contentEncoding,
            if (respDecryptedHit) 'decryptedText': respDecrypted,
            if (respDecryptedHit) 'decryptedRule': respDecryptedRule,
            if (resp.messages.isNotEmpty) 'messages': resp.messages.map(_frameSummary).toList(),
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
  return _ok(await _reqDetail(reqs[index]));
}

// ---- search_requests ----
Future<Map<String, dynamic>> toolSearchRequests(Map<String, dynamic> args) async {
  final urlKw = args['urlKeyword'] as String?;
  final bodyKw = args['bodyKeyword'] as String?;
  final limit = _toInt(args, 'limit', 50);
  final reqs = await _allRequests();
  final results = <Map<String, dynamic>>[];
  for (final r in reqs) {
    final detail = await _reqDetail(r);
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
    final list = detail
        ? await Future.wait(reqs.map((r) => _reqDetail(r)).toList())
        : reqs.map(_reqSummary).toList();
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
    return _ok(await _reqDetail(reqs[reqIndex]));
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

// ---- list_rewrite_rules ----
Future<Map<String, dynamic>> toolListRewriteRules(Map<String, dynamic> args) async {
  try {
    final m = await RequestRewriteManager.instance;
    final list = m.rules
        .map((r) => {'enabled': r.enabled, 'name': r.name, 'url': r.url, 'type': r.type.name, 'method': r.method?.name})
        .toList();
    return _ok({'total': list.length, 'rules': list});
  } catch (e) {
    return _err('list rewrite rules failed: ${e.toString()}');
  }
}

// ---- add_rewrite_rule ----
Future<Map<String, dynamic>> toolAddRewriteRule(Map<String, dynamic> args) async {
  try {
    final m = await RequestRewriteManager.instance;
    final url = args['url'] as String? ?? '';
    final typeStr = args['ruleType'] as String? ?? 'responseReplace';
    final name = args['name'] as String?;
    final body = args['body'] as String?;
    final redirectUrl = args['redirectUrl'] as String?;

    RuleType type;
    try {
      type = RuleType.values.firstWhere((e) => e.name == typeStr);
    } catch (_) {
      type = RuleType.responseReplace;
    }

    final rule = RequestRewriteRule(name: name, url: url, type: type);
    final items = <RewriteItem>[];

    switch (type) {
      case RuleType.redirect:
        if (redirectUrl != null && redirectUrl.isNotEmpty) {
          items.add(RewriteItem(RewriteType.redirect, true)..redirectUrl = redirectUrl);
        }
        break;
      case RuleType.responseReplace:
        if (body != null) {
          items.add(RewriteItem(RewriteType.replaceResponseBody, true)..body = body);
        }
        final statusCode = (args['statusCode'] as num?)?.toInt();
        if (statusCode != null) {
          items.add(RewriteItem(RewriteType.replaceResponseStatus, true)..statusCode = statusCode);
        }
        final headers = args['headers'];
        if (headers is Map) {
          items.add(RewriteItem(RewriteType.replaceResponseHeader, true)
            ..headers = headers.map((k, v) => MapEntry(k.toString(), v.toString())));
        }
        break;
      case RuleType.requestReplace:
        if (body != null) {
          items.add(RewriteItem(RewriteType.replaceRequestBody, true)..body = body);
        }
        break;
      case RuleType.responseUpdate:
        if (body != null) {
          items.add(RewriteItem(RewriteType.updateBody, true)..body = body);
        }
        break;
      case RuleType.requestUpdate:
        if (body != null) {
          items.add(RewriteItem(RewriteType.updateBody, true)..body = body);
        }
        break;
    }

    if (items.isEmpty) {
      return _err('no rewrite content provided');
    }
    await m.addRule(rule, items);
    return _ok('rewrite rule added');
  } catch (e) {
    return _err('add rewrite rule failed: ${e.toString()}');
  }
}

// ---- remove_rewrite_rule ----
Future<Map<String, dynamic>> toolRemoveRewriteRule(Map<String, dynamic> args) async {
  try {
    final m = await RequestRewriteManager.instance;
    final index = _toInt(args, 'index', -1);
    if (index < 0 || index >= m.rules.length) return _err('index out of range');
    await m.removeIndex([index]);
    return _ok('rewrite rule removed');
  } catch (e) {
    return _err('remove rewrite rule failed: ${e.toString()}');
  }
}

// ---- set_weak_network_enabled ----
Future<Map<String, dynamic>> toolSetWeakNetworkEnabled(Map<String, dynamic> args) async {
  try {
    final m = await NetworkConditionManager.instance;
    final enable = args['enable'] as bool?;
    if (enable == null) return _err('enable is required');
    m.enabled = enable;
    await m.flushConfig();
    return _ok({'enabled': m.enabled});
  } catch (e) {
    return _err('set weak network enabled failed: ${e.toString()}');
  }
}

// ---- list_pending_intercepts ----
Future<Map<String, dynamic>> toolListPendingIntercepts(Map<String, dynamic> args) async {
  try {
    final bp = RequestBreakpointInterceptor.instance;
    final reqs = bp.pendingRequestIds().map((id) => bp.pendingRequestSummary(id)).whereType<Map<String, dynamic>>().toList();
    final resps = bp.pendingResponseIds().map((id) => bp.pendingResponseSummary(id)).whereType<Map<String, dynamic>>().toList();
    return _ok({'requests': reqs, 'responses': resps, 'total': reqs.length + resps.length});
  } catch (e) {
    return _err('list pending intercepts failed: ${e.toString()}');
  }
}

// ---- release_intercept ----
Future<Map<String, dynamic>> toolReleaseIntercept(Map<String, dynamic> args) async {
  try {
    final bp = RequestBreakpointInterceptor.instance;
    final requestId = args['requestId'] as String?;
    if (requestId == null || requestId.isEmpty) return _err('requestId is required');

    // 收集可选覆盖字段
    Map<String, dynamic>? modify;
    if (args['method'] != null || args['uri'] != null || args['headers'] != null || args['body'] != null) {
      modify = {};
      if (args['method'] != null) modify['method'] = args['method'];
      if (args['uri'] != null) modify['uri'] = args['uri'];
      if (args['headers'] is Map) {
        modify['headers'] =
            (args['headers'] as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
      }
      if (args['body'] != null) modify['body'] = args['body'];
    }

    // 请求与响应都可放行
    if (bp.releaseRequestById(requestId, modify: modify)) {
      return _ok({'released': 'request', 'requestId': requestId});
    }
    if (bp.releaseResponseById(requestId, modify: modify)) {
      return _ok({'released': 'response', 'requestId': requestId});
    }
    return _err('no pending intercept found for requestId: $requestId');
  } catch (e) {
    return _err('release intercept failed: ${e.toString()}');
  }
}

// ---- abort_intercepts ----
Future<Map<String, dynamic>> toolAbortIntercepts(Map<String, dynamic> args) async {
  try {
    final bp = RequestBreakpointInterceptor.instance;
    final count = bp.abortAllRequests();
    return _ok({'aborted': count});
  } catch (e) {
    return _err('abort intercepts failed: ${e.toString()}');
  }
}

// ---- 加解密 ----
CryptoKeyConfig _cryptoConfigFromArgs(Map<String, dynamic> args, {CryptoKeyConfig? base}) {
  final b = base ?? CryptoKeyConfig.defaults();
  return b.copyWith(
    key: args['key'] as String?,
    iv: args['iv'] as String?,
    ivSource: args['ivSource'] as String?,
    ivPrefixLength: _toInt(args, 'ivPrefixLength', b.ivPrefixLength),
    mode: args['mode'] as String?,
    padding: args['padding'] as String?,
    keyLength: _toInt(args, 'keyLength', b.keyLength),
  );
}

// ---- list_crypto_rules ----
Future<Map<String, dynamic>> toolListCryptoRules(Map<String, dynamic> args) async {
  try {
    final m = await RequestCryptoManager.instance;
    final rules = m.rules.asMap().entries.map((e) {
      final r = e.value;
      return {
        'index': e.key,
        'name': r.name,
        'urlPattern': r.urlPattern,
        'field': r.field,
        'enabled': r.enabled,
        'config': r.config.toJson(),
      };
    }).toList();
    return _ok({'enabled': m.enabled, 'rules': rules});
  } catch (e) {
    return _err('list crypto rules failed: ${e.toString()}');
  }
}

// ---- add_crypto_rule ----
Future<Map<String, dynamic>> toolAddCryptoRule(Map<String, dynamic> args) async {
  try {
    final m = await RequestCryptoManager.instance;
    final urlPattern = args['urlPattern'] as String?;
    final key = args['key'] as String?;
    if (urlPattern == null || urlPattern.isEmpty) return _err('urlPattern is required');
    if (key == null || key.isEmpty) return _err('key is required');

    final rule = CryptoRule(
      name: args['name'] as String? ?? 'mcp-crypto',
      urlPattern: urlPattern,
      field: args['field'] as String?,
      enabled: args['enabled'] as bool? ?? true,
      config: _cryptoConfigFromArgs(args),
    );
    m.rules.add(rule);
    await m.flushConfig();
    return _ok({'added': true, 'index': m.rules.length - 1});
  } catch (e) {
    return _err('add crypto rule failed: ${e.toString()}');
  }
}

// ---- update_crypto_rule ----
Future<Map<String, dynamic>> toolUpdateCryptoRule(Map<String, dynamic> args) async {
  try {
    final m = await RequestCryptoManager.instance;
    final index = _toInt(args, 'index', -1);
    if (index < 0 || index >= m.rules.length) return _err('index out of range');
    final old = m.rules[index];
    final rule = old.copyWith(
      name: args['name'] as String?,
      urlPattern: args['urlPattern'] as String?,
      field: args['field'] as String?,
      enabled: args['enabled'] as bool?,
      config: _cryptoConfigFromArgs(args, base: old.config),
    );
    m.rules[index] = rule;
    await m.flushConfig();
    return _ok({'updated': true, 'index': index});
  } catch (e) {
    return _err('update crypto rule failed: ${e.toString()}');
  }
}

// ---- remove_crypto_rule ----
Future<Map<String, dynamic>> toolRemoveCryptoRule(Map<String, dynamic> args) async {
  try {
    final m = await RequestCryptoManager.instance;
    final index = _toInt(args, 'index', -1);
    if (index < 0 || index >= m.rules.length) return _err('index out of range');
    m.rules.removeAt(index);
    await m.flushConfig();
    return _ok({'removed': true, 'index': index});
  } catch (e) {
    return _err('remove crypto rule failed: ${e.toString()}');
  }
}

// ---- set_crypto_enabled ----
Future<Map<String, dynamic>> toolSetCryptoEnabled(Map<String, dynamic> args) async {
  try {
    final m = await RequestCryptoManager.instance;
    final enable = args['enable'] as bool?;
    if (enable == null) return _err('enable is required');
    m.enabled = enable;
    await m.flushConfig();
    return _ok({'enabled': m.enabled});
  } catch (e) {
    return _err('set crypto enabled failed: ${e.toString()}');
  }
}

// ---- decrypt_body ----
Future<Map<String, dynamic>> toolDecryptBody(Map<String, dynamic> args) async {
  try {
    final body = args['body'] as String?;
    final key = args['key'] as String?;
    if (body == null || body.isEmpty) return _err('body is required');
    if (key == null || key.isEmpty) return _err('key is required');

    final config = _cryptoConfigFromArgs(args);

    // 输入解析: 优先按 base64 解码, 否则按 utf8 原文
    Uint8List cipher;
    final trimmed = body.trim();
    try {
      cipher = base64.decode(trimmed);
    } catch (_) {
      cipher = utf8.encode(body);
    }

    // prefix 模式: 取前 N 字节作 IV
    Uint8List ivBytes = Uint8List(0);
    if (config.mode == 'CBC' && config.ivSource == 'prefix') {
      final n = config.ivPrefixLength;
      if (cipher.length <= n) return _err('cipher too short for prefix IV (len=${cipher.length}, need >$n)');
      ivBytes = cipher.sublist(0, n);
      cipher = cipher.sublist(n);
      // 非 PKCS7 需要块对齐
      if (config.padding != 'PKCS7' && cipher.length % 16 != 0) {
        return _err('cipher length ${cipher.length} not multiple of 16 (non-PKCS7 padding)');
      }
    }

    final decrypted = AesUtils.decrypt(
      cipher,
      key: config.key,
      keyLength: config.keyLength,
      mode: config.mode,
      padding: config.padding,
      iv: (config.mode == 'CBC' && config.ivSource == 'prefix')
          ? 'base64:${base64.encode(ivBytes)}'
          : (config.mode == 'CBC' ? config.iv : null),
    );

    // 结果: 尝试 utf8 解码为文本, 同时给 base64/hex 备选
    String text;
    String? utf8Text;
    try {
      utf8Text = utf8.decode(decrypted);
      text = utf8Text;
    } catch (_) {
      utf8Text = null;
      text = '';
    }
    return _ok({
      'decryptedText': text,
      'decryptedBase64': base64.encode(decrypted),
      'decryptedHex': decrypted.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'decryptedLength': decrypted.length,
      'utf8Valid': utf8Text != null,
    });
  } catch (e) {
    return _err('decrypt failed: ${e.toString()}');
  }
}

// ---- encrypt_body ----
Future<Map<String, dynamic>> toolEncryptBody(Map<String, dynamic> args) async {
  try {
    final body = args['body'] as String?;
    final key = args['key'] as String?;
    if (body == null || body.isEmpty) return _err('body is required');
    if (key == null || key.isEmpty) return _err('key is required');

    final config = _cryptoConfigFromArgs(args);
    final plain = utf8.encode(body);

    // prefix 模式: 自动生成随机 IV 前置到密文
    Uint8List prefixIv = Uint8List(0);
    if (config.mode == 'CBC' && config.ivSource == 'prefix') {
      final n = config.ivPrefixLength;
      final rnd = Random.secure();
      prefixIv = Uint8List(n);
      for (var i = 0; i < n; i++) {
        prefixIv[i] = rnd.nextInt(256);
      }
    }

    final encrypted = AesUtils.encrypt(
      plain,
      key: config.key,
      keyLength: config.keyLength,
      mode: config.mode,
      padding: config.padding,
      iv: (config.mode == 'CBC' && config.ivSource == 'prefix')
          ? 'base64:${base64.encode(prefixIv)}'
          : (config.mode == 'CBC' ? config.iv : null),
    );

    // prefix 模式: IV 拼到密文前
    final Uint8List full;
    if (config.mode == 'CBC' && config.ivSource == 'prefix') {
      full = Uint8List(prefixIv.length + encrypted.length);
      full.setRange(0, prefixIv.length, prefixIv);
      full.setRange(prefixIv.length, full.length, encrypted);
    } else {
      full = encrypted;
    }

    return _ok({
      'encryptedBase64': base64.encode(full),
      'encryptedHex': full.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'encryptedLength': full.length,
      'mode': config.mode,
      'ivSource': config.ivSource,
      'ivPrefixLength': config.ivPrefixLength,
      // prefix 模式返回实际使用的 IV,便于对照
      if (config.mode == 'CBC' && config.ivSource == 'prefix')
        'generatedIvBase64': base64.encode(prefixIv),
    });
  } catch (e) {
    return _err('encrypt failed: ${e.toString()}');
  }
}

// ---- detect_body_encoding ----
Future<Map<String, dynamic>> toolDetectBodyEncoding(Map<String, dynamic> args) async {
  try {
    final body = args['body'] as String?;
    if (body == null || body.isEmpty) return _err('body is required');
    final s = body.trim();

    final result = <String, dynamic>{'inputLength': s.length};

    // 1. gzip 魔数 (输入可能是原始字节的 base64 或文本里的转义)
    // 3. hex 检测: 偶数长度 + 全部 hex 字符
    final isHex = s.length % 2 == 0 && s.length >= 2 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);

    // 4. base64 检测: 合法字符集 + 可解码
    Uint8List? b64Bytes;
    var isBase64 = false;
    // 纯 hex 字符串不算 base64(它是 hex); 只有含非 hex 字符(+/ 或非等长)才考虑 base64
    final couldBeB64 = RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(s) && s.length % 4 == 0 && s.length >= 4;
    if (couldBeB64 && !(isHex && RegExp(r'^[0-9a-fA-F]+$').hasMatch(s))) {
      try {
        b64Bytes = base64.decode(s);
        isBase64 = true;
      } catch (_) {}
    }

    // 5. URL 编码检测
    final isUrlEncoded = s.contains('%') && RegExp(r'%[0-9a-fA-F]{2}').hasMatch(s);

    // 5.5 base64 解码后若是 JSON, 也标记 json (如快手 neoParams = base64(JSON))
    String? jsonPreview;
    var isJson = false;
    try {
      final decoded = jsonDecode(s);
      isJson = true;
      jsonPreview = jsonEncode(decoded);
    } catch (_) {}
    if (!isJson && b64Bytes != null) {
      try {
        final inner = utf8.decode(b64Bytes);
        final decoded = jsonDecode(inner);
        isJson = true;
        jsonPreview = jsonEncode(decoded);
      } catch (_) {}
    }

    // 6. 疑似 AES 密文: base64 解码后长度 16 对齐且非纯文本
    Uint8List? candidateBytes;
    if (isBase64 && b64Bytes != null) {
      candidateBytes = b64Bytes;
    } else if (isHex) {
      candidateBytes = Uint8List.fromList(List.generate(s.length ~/ 2, (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)));
    }
    if (candidateBytes != null) {
      final len = candidateBytes.length;
      var looksEncrypted = len > 0 && len % 16 == 0;
      // 若解码后是纯 utf8 文本, 不太像密文
      if (looksEncrypted) {
        try {
          utf8.decode(candidateBytes);
          looksEncrypted = false; // 可解码为文本, 更像普通内容
        } catch (_) {}
      }
      result['decodedLength'] = len;
      result['blockAligned16'] = len % 16 == 0;
      result['looksLikeAesCipher'] = looksEncrypted;
      result['decodedHeadHex'] = candidateBytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    }

    // 汇总判定
    final formats = <String>[];
    if (isJson) formats.add('json');
    if (isBase64) formats.add('base64');
    if (isHex) formats.add('hex');
    if (isUrlEncoded) formats.add('urlencoded');
    result['detected'] = formats;
    result['isJson'] = isJson;
    result['jsonPreview'] = jsonPreview != null && jsonPreview.length > 500 ? jsonPreview.substring(0, 500) : jsonPreview;
    result['isBase64'] = isBase64;
    result['isHex'] = isHex;
    result['isUrlEncoded'] = isUrlEncoded;
    result['isGzipMagic'] = (b64Bytes != null && b64Bytes.length >= 2 && b64Bytes[0] == 0x1f && b64Bytes[1] == 0x8b) ||
        (s.length >= 2 && s.codeUnitAt(0) == 0x1f && s.codeUnitAt(1) == 0x8b);

    return _ok(result);
  } catch (e) {
    return _err('detect failed: ${e.toString()}');
  }
}

// ---- analyze_signature ----
/// 分析单段签名(如 xfalcon 的 HUDR_xxx 或 TE_xxx), 返回摘要或 null
Map<String, dynamic>? _analyzeSigSegment(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  final res = <String, dynamic>{'segment': s.length > 60 ? '${s.substring(0, 60)}...' : s, 'len': s.length};

  // 剥离前缀 XXX_
  final pm = RegExp(r'^([A-Za-z0-9]{2,10})_([A-Za-z0-9+/=]+)$').firstMatch(s);
  if (pm != null) {
    final prefix = pm.group(1)!;
    final rest = pm.group(2)!;
    final restIsHex = RegExp(r'^[0-9a-fA-F]+$').hasMatch(rest) && rest.length % 2 == 0;
    final restIsB64 = RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(rest) && rest.length % 4 == 0;
    if (restIsHex || restIsB64) {
      res['prefix'] = prefix;
      s = rest;
      res['strippedLen'] = s.length;
    }
  }

  // hex 识别
  if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(s) && s.length % 2 == 0) {
    res['format'] = 'hex';
    final n = s.length;
    final cand = <String>[];
    if (n == 32) cand.add('MD5 / HmacMD5');
    if (n == 40) cand.add('SHA1 / HmacSHA1');
    if (n == 48) cand.add('24字节 → AES-192 密文 / MD5+SHA1 拼接');
    if (n == 56) cand.add('SHA224 / HmacSHA224');
    if (n == 64) cand.add('SHA256 / HmacSHA256');
    if (n == 96) cand.add('SHA384 / HmacSHA384');
    if (n == 128) cand.add('SHA512 / HmacSHA512 / AES-256 密文');
    if (n % 32 == 0 && n >= 64) cand.add('多个哈希拼接 或 AES 密文(${n ~/ 2}字节, ${n ~/ 32}块)');
    if (cand.isEmpty) cand.add('${n ~/ 2}字节hex, 非标准哈希长度 → 加密数据(如AES-CBC含IV)/自定义编码');
    res['possibleAlgorithms'] = cand;
    return res;
  }

  // base64 识别
  if (RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(s) && s.length % 4 == 0 && s.length >= 4) {
    res['format'] = 'base64';
    try {
      final bytes = base64.decode(s);
      res['decodedLen'] = bytes.length;
      if (bytes.length == 16) res['hint'] = '16字节 → AES-128密文块 / 原始MD5摘要';
      if (bytes.length == 32) res['hint'] = '32字节 → AES-256密文块 / SHA256原始摘要';
      if (bytes.length % 16 != 0) res['hint'] = '非16对齐(${bytes.length}字节), 可能非AES密文';
      try {
        final t = utf8.decode(bytes);
        res['textPreview'] = t.length > 60 ? t.substring(0, 60) : t;
      } catch (_) {}
    } catch (_) {}
    return res;
  }

  res['format'] = 'unknown';
  return res;
}

Future<Map<String, dynamic>> toolAnalyzeSignature(Map<String, dynamic> args) async {
  try {
    final value = args['value'] as String?;
    if (value == null || value.isEmpty) return _err('value is required');
    var s = value.trim();

    final result = <String, dynamic>{
      'length': s.length,
      'input': s.length > 100 ? '${s.substring(0, 100)}...' : s,
    };

    // 0. 常见前缀剥离: HUDR_ / TE_ / sig_ / ts_ 等 (快手 xfalcon 等签名带标识前缀)
    //    以及 '$' 分段结构 (如 HUDR_<base64>$TE_<hex>)
    if (s.contains(r'$')) {
      final segs = s.split(r'$');
      final segResults = <Map<String, dynamic>>[];
      for (final seg in segs) {
        final segRes = _analyzeSigSegment(seg);
        if (segRes != null) segResults.add(segRes);
      }
      if (segResults.isNotEmpty) {
        result['segments'] = segResults;
        return _ok(result);
      }
    }
    final prefixMatch = RegExp(r'^([A-Za-z0-9]{2,10})_([A-Za-z0-9+/=]+)$').firstMatch(s);
    if (prefixMatch != null) {
      final prefix = prefixMatch.group(1)!;
      final rest = prefixMatch.group(2)!;
      // 前缀后内容确实是 hex 或 base64 才剥离(避免误伤普通文本)
      final restIsHex = RegExp(r'^[0-9a-fA-F]+$').hasMatch(rest) && rest.length % 2 == 0;
      final restIsB64 = RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(rest) && rest.length % 4 == 0;
      if (restIsHex || restIsB64) {
        result['prefix'] = prefix;
        s = rest;
        result['strippedLength'] = s.length;
      }
    }

    // 1. hex 检测 + 哈希算法识别
    final isHex = RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);
    result['isHex'] = isHex;
    if (isHex) {
      final n = s.length;
      final candidates = <String>[];
      if (n == 32) candidates.add('MD5 / HmacMD5(最常见, 如参数拼接后md5) / 也可能是AES-128-ECB密文hex');
      if (n == 40) candidates.add('SHA1 / HmacSHA1');
      if (n == 48) candidates.add('24字节 → AES-192 密文 / MD5+SHA1 拼接 / HmacMD5(2轮)');
      if (n == 56) candidates.add('SHA224 / HmacSHA224');
      if (n == 64) candidates.add('SHA256 / HmacSHA256');
      if (n == 96) candidates.add('SHA384 / HmacSHA384');
      if (n == 128) candidates.add('SHA512 / HmacSHA512 / AES-256 密文');
      if (n % 32 == 0 && n >= 64) candidates.add('可能为多个哈希拼接 或 AES 密文(${n ~/ 2}字节, ${n ~/ 32}个块)');
      if (n % 2 == 0 && candidates.isEmpty && n > 0) {
        candidates.add('${n ~/ 2}字节hex, 非标准哈希长度, 可能为加密数据(如AES-CBC含IV)/自定义编码/拼接');
      }
      result['possibleAlgorithms'] = candidates;
    }

    // 2. base64 检测
    final isB64 = RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(s) && s.length % 4 == 0;
    result['isBase64'] = isB64;
    if (isB64 && !(isHex && s.length % 2 == 0)) {
      try {
        final bytes = base64.decode(s);
        result['base64DecodedLength'] = bytes.length;
        // base64 解码后如果是 hex 长度匹配也提示
        if (bytes.length == 16) result['base64DecodedHint'] = '16字节 → 可能为 AES-128 密文块 / 原始MD5摘要';
        if (bytes.length == 32) result['base64DecodedHint'] = '32字节 → 可能为 AES-256 密文块 / SHA256原始摘要';
        // 是否像文本
        try {
          final t = utf8.decode(bytes);
          result['base64TextPreview'] = t.length > 60 ? t.substring(0, 60) : t;
        } catch (_) {}
      } catch (_) {}
    }

    // 3. 常见拼接特征: k=v&k=v 形式 (签名常基于参数拼接)
    if (s.contains('&') && s.contains('=')) {
      final params = s.split('&').where((p) => p.contains('=')).length;
      result['looksLikeParamString'] = true;
      result['paramCount'] = params;
    }

    // 4. 时间戳/随机串特征
    if (RegExp(r'^\d{10}$').hasMatch(s)) result['possibleAlgorithms'] = ['Unix秒级时间戳(10位)'];
    if (RegExp(r'^\d{13}$').hasMatch(s)) result['possibleAlgorithms'] = ['Unix毫秒时间戳(13位)'];

    return _ok(result);
  } catch (e) {
    return _err('analyze signature failed: ${e.toString()}');
  }
}

// ---- replay_request ----
Future<Map<String, dynamic>> toolReplayRequest(Map<String, dynamic> args) async {
  try {
    final url = args['url'] as String?;
    if (url == null || url.isEmpty) return _err('url is required');

    final methodStr = (args['method'] as String? ?? 'GET').toUpperCase();
    final HttpMethod method;
    try {
      method = HttpMethod.values.firstWhere((m) => m.name.toUpperCase() == methodStr);
    } catch (_) {
      return _err('unsupported method: $methodStr');
    }

    // 构造请求
    final request = HttpRequest(method, url);
    if (args['headers'] is Map) {
      (args['headers'] as Map).forEach((k, v) {
        request.headers.set(k.toString(), v.toString());
      });
    }
    final body = args['body'] as String?;
    if (body != null && body.isNotEmpty) {
      request.body = utf8.encode(body);
      if (request.headers.contentType.isEmpty) {
        request.headers.contentType = 'application/x-www-form-urlencoded';
      }
    }

    // 走本地代理(与 App 重放一致): 代理运行时经 127.0.0.1:port
    final proxy = ProxyServer.current;
    final ProxyInfo? proxyInfo =
        (proxy?.isRunning == true) ? ProxyInfo.of('127.0.0.1', proxy!.port) : null;
    final timeout = Duration(seconds: _toInt(args, 'timeoutSeconds', 15));

    final sw = Stopwatch()..start();
    final response = await HttpClients.proxyRequest(request, proxyInfo: proxyInfo, timeout: timeout);
    sw.stop();

    // 响应体明文(解压后, 前2000字符)
    String bodyText = '';
    try {
      bodyText = response.getBodyString();
      if (bodyText.length > 2000) bodyText = '${bodyText.substring(0, 2000)}...(共${bodyText.length}字符)';
    } catch (_) {}

    return _ok({
      'statusCode': response.status.code,
      'statusReason': response.status.reasonPhrase,
      'timeMs': sw.elapsedMilliseconds,
      'responseHeaders': response.headers.toJson(),
      'responseBody': bodyText,
      'responseBodyBase64': _safeBase64(response.body),
      'contentEncoding': response.headers.contentEncoding,
    });
  } catch (e) {
    return _err('replay request failed: ${e.toString()}');
  }
}
