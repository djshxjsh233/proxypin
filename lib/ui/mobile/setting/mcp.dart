import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/mcp/mcp_manager.dart';
import 'package:proxypin/ui/component/widgets.dart';

/// MCP 服务设置页：对齐第三方 MCP 界面（端口/自启动/连接信息/JSON配置/启动停止）。
class McpPageMobile extends StatefulWidget {
  const McpPageMobile({super.key});

  @override
  State<McpPageMobile> createState() => _McpPageMobileState();
}

class _McpPageMobileState extends State<McpPageMobile> {
  McpManager? _manager;
  bool _running = false;
  final _portController = TextEditingController();
  late bool _autoStart = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _manager = await McpManager.instance;
    final config = _manager!.config;
    _portController.text = '${config.port}';
    setState(() {
      _autoStart = config.autoStart;
      _running = _manager!.isRunning;
    });
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _running = _manager?.isRunning ?? false;
    });
  }

  Future<void> _toggleServer() async {
    final manager = _manager;
    if (manager == null) return;
    if (manager.isRunning) {
      await manager.stop();
      if (!mounted) return;
      FlutterToastr.show('MCP 服务已停止', context);
    } else {
      final ok = await manager.start();
      if (!mounted) return;
      FlutterToastr.show(ok ? 'MCP 服务已启动 (端口 ${manager.config.port})' : '启动失败，请检查端口', context);
    }
    _refresh();
  }

  Future<void> _savePort() async {
    final manager = _manager;
    if (manager == null) return;
    final text = _portController.text.trim();
    final port = int.tryParse(text);
    if (port == null || port < 1024 || port > 65535) {
      if (!mounted) return;
      FlutterToastr.show('请输入有效端口 (1024-65535)', context);
      _portController.text = '${manager.config.port}';
      return;
    }
    await manager.setPort(port);
    if (!mounted) return;
    FlutterToastr.show('端口已保存（重启服务后生效）', context);
  }

  Future<void> _toggleAutoStart(bool v) async {
    final manager = _manager;
    if (manager == null) return;
    setState(() => _autoStart = v);
    await manager.setAutoStart(v);
  }

  Future<void> _copyConfig() async {
    final manager = _manager;
    if (manager == null) return;
    final json = jsonEncode({
      'mcpServers': {
        'proxypin': {'url': 'http://127.0.0.1:${manager.config.port}/mcp'}
      }
    });
    try {
      await Clipboard.setData(ClipboardData(text: json));
      if (!mounted) return;
      FlutterToastr.show('MCP 配置已复制', context);
    } catch (e) {
      if (!mounted) return;
      FlutterToastr.show('复制失败', context);
    }
  }

  Widget _section(List<Widget> tiles) => Card(
        color: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
            side: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.13)),
            borderRadius: BorderRadius.circular(10)),
        child: Column(children: tiles),
      );

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 130, child: Text(label, style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
            Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final manager = _manager;
    final port = manager?.config.port ?? 9010;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP Server', style: TextStyle(fontSize: 18)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(_running ? Icons.stop_circle_outlined : Icons.play_circle_outline),
            tooltip: _running ? '停止服务' : '启动服务',
            onPressed: _toggleServer,
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        // 运行状态徽章
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: (_running ? Colors.green : Colors.grey).withValues(alpha: isDark ? 0.2 : 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _running ? Colors.green : Colors.grey,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _running ? '正在运行，端口 $port' : '服务未启动',
                  style: TextStyle(
                      fontSize: 13, color: _running ? Colors.green : Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ),

        // 端口 + 自启动
        _section([
          ListTile(
            leading: const Icon(Icons.numbers),
            title: const Text('端口号', style: TextStyle(fontSize: 15)),
            subtitle: const Text('停止服务后可修改端口', style: TextStyle(fontSize: 12)),
            trailing: SizedBox(
              width: 90,
              child: TextField(
                controller: _portController,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                onSubmitted: (_) => _savePort(),
              ),
            ),
            onTap: _savePort,
          ),
          Divider(height: 0, thickness: 0.3, color: Theme.of(context).dividerColor.withValues(alpha: 0.22)),
          ListTile(
            leading: const Icon(Icons.autorenew),
            title: const Text('App 启动时自动开启 MCP 服务', style: TextStyle(fontSize: 15)),
            trailing: SwitchWidget(value: _autoStart, onChanged: _toggleAutoStart, scale: 0.8),
          ),
        ]),
        const SizedBox(height: 12),

        // 连接信息
        _section([
          const ListTile(
            leading: Icon(Icons.link),
            title: Text('连接信息', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(children: [
              _infoRow('Streamable HTTP (推荐)', 'http://127.0.0.1:$port/mcp'),
              _infoRow('SSE Endpoint (旧版)', 'http://127.0.0.1:$port/sse'),
              _infoRow('Health Check', 'http://127.0.0.1:$port/health'),
            ]),
          ),
        ]),
        const SizedBox(height: 12),

        // MCP 配置 JSON
        _section([
          const ListTile(
            leading: Icon(Icons.code),
            title: Text('MCP 配置 (JSON)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
            trailing: Icon(Icons.copy, size: 20),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SelectableText(
              jsonEncode({
                'mcpServers': {
                  'proxypin': {'url': 'http://127.0.0.1:$port/mcp'}
                }
              }),
              style: TextStyle(fontSize: 13, fontFamily: 'monospace', color: isDark ? Colors.greenAccent.shade200 : Colors.blueGrey.shade800),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: _copyConfig, child: const Text('复制配置')),
          ),
        ]),
        const SizedBox(height: 20),

        // 启动/停止主按钮
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: FilledButton.icon(
            icon: Icon(_running ? Icons.stop : Icons.play_arrow),
            label: Text(_running ? '停止服务' : '启动服务'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: _running ? Colors.red.withValues(alpha: 0.8) : null,
            ),
            onPressed: _toggleServer,
          ),
        ),
      ]),
    );
  }
}
