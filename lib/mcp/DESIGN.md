# ProxyPin MCP Server 设计方案

## 目标
在 fork 的 ProxyPin (djshxjsh233/proxypin) 内嵌一个 Dart MCP server：
- 监听 127.0.0.1:9010, MCP Streamable HTTP/JSON-RPC 协议
- 无缝替换现有第三方 9010 MCP (Agent 端配置不用改)
- 直接调用 ProxyPin 内核 API, 能力远超现有工具

## 架构
```
lib/mcp/
  mcp_server.dart       # MCP HTTP server (dart:io HttpServer) + JSON-RPC 路由
  mcp_tools.dart        # 工具定义(名称/描述/参数schema)注册表
  mcp_handler_network.dart  # 网络能力: 抓包/重放/断点/重写/map/block/script/hosts/弱网
  mcp_handler_device.dart   # 设备能力(SU, 后期): shell/screenshot/ui
  mcp_config.dart       # MCP配置(端口/开关/自启动) + 持久化
  mcp_tool.dart         # 工具基类
lib/ui/mobile/setting/mcp.dart   # 设置页 MCP 入口
```

## MCP 协议 (MCP Streamable HTTP - 与 minis-mcp-cli 兼容)
- Endpoint: /mcp
- 支持 GET(sse) + POST(json-rpc)
- JSON-RPC 2.0: initialize / tools/list / tools/call / notifications

## 工具清单 (一期: 全覆盖现有25个 + 内核深层)
### 抓包查询 (对齐现有)
- get_request_list         列表(过滤/分页)
- get_request_detail        详情(请求头/体/响应)
- get_request_body          单独请求体/响应体
- search_requests           高级搜索
- get_request_stats         统计(域名/状态码/方法/耗时)
- get_domain_summary        域名汇总
- get_cookie_info           Cookie
- compare_requests          对比两个请求
- find_sensitive_data       敏感信息扫描
- extract_api_endpoints     API 端点提取
- analyze_auth              认证信息分析

### 网络操控 (调内核, 新增/增强)
- start_capture / stop_capture   抓包开关
- clear_requests                 清空历史
- replay_request                 重放(覆盖头/体)
- add_breakpoint / list_breakpoints / remove_breakpoint / get_pending_intercepts / release_intercept  断点
- list_rewrite_rules / add_rewrite_rule / remove_rewrite_rule  重写
- list_scripts / get_script_content / create_or_update_script  脚本
- list_map_rules / add_map_rule / remove_map_rule                URL映射(新增)
- list_block_rules / add_block_rule / remove_block_rule          屏蔽(新增)
- list_hosts / add_hosts / remove_hosts                          hosts(新增)
- list_weak_network / set_weak_network                           弱网(新增)

### 代理/系统 (新增)
- get_proxy_status / set_proxy_status     代理开关
- get_configuration                       配置读取

## 内核 API 映射
- 历史: HistoryStorage.instance → _histories (ListenableList<HistoryItem>)
- 断点: RequestBreakpointManager.instance
- 重写: RequestRewriteManager.instance
- map: RequestMapManager.instance
- block: RequestBlockManager.instance
- 脚本: ScriptManager.instance
- hosts: HostsManager.instance
- 弱网: NetworkConditionManager.instance
- 配置: Configuration.instance
- server: ProxyServer
