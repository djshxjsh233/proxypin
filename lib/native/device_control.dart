import 'package:flutter/services.dart';

/// 设备控制(原生通道): shell / 启动App / 截图 / UI控制
class DeviceControl {
  static const MethodChannel _channel = MethodChannel('com.proxy/deviceControl');

  /// 执行 shell 命令 (默认 su root)
  static Future<Map<dynamic, dynamic>> runShell(String command, {bool useSu = true}) async {
    return await _channel.invokeMethod('runShell', {'command': command, 'use_su': useSu});
  }

  /// 查询私有 sqlite 数据库 (root)
  static Future<Map<dynamic, dynamic>> sqliteQuery(String dbPath, String query) async {
    return await _channel.invokeMethod('sqliteQuery', {'dbPath': dbPath, 'query': query});
  }

  /// 读取私有文件 (root)
  static Future<Map<dynamic, dynamic>> readFile(String path) async {
    return await _channel.invokeMethod('readFile', {'path': path});
  }

  /// 列出目录内容 (root, 可看 /data)
  static Future<Map<dynamic, dynamic>> listDir(String path) async {
    return await _channel.invokeMethod('listDir', {'path': path});
  }

  /// 写文件 (root)
  static Future<Map<dynamic, dynamic>> writeFile(String path, String content) async {
    return await _channel.invokeMethod('writeFile', {'path': path, 'content': content});
  }

  /// 复制文件 (root)
  static Future<Map<dynamic, dynamic>> copyFile(String src, String dst) async {
    return await _channel.invokeMethod('copyFile', {'src': src, 'dst': dst});
  }

  /// 移动文件 (root)
  static Future<Map<dynamic, dynamic>> moveFile(String src, String dst) async {
    return await _channel.invokeMethod('moveFile', {'src': src, 'dst': dst});
  }

  /// 删除文件/目录 (root)
  static Future<Map<dynamic, dynamic>> deleteFile(String path) async {
    return await _channel.invokeMethod('deleteFile', {'path': path});
  }

  /// 当前前台 Activity
  static Future<Map<dynamic, dynamic>> getForegroundActivity() async {
    return await _channel.invokeMethod('getForegroundActivity');
  }

  /// logcat 抓日志
  static Future<Map<dynamic, dynamic>> logcat({String package = '', int lines = 200, bool clear = false}) async {
    return await _channel.invokeMethod('logcat', {'package': package, 'lines': lines, 'clear': clear});
  }

  /// 启动 App
  static Future<bool> launchApp(String packageName) async {
    return await _channel.invokeMethod('launchApp', {'packageName': packageName});
  }

  /// 截图 (返回 base64 + path)
  static Future<Map<dynamic, dynamic>> takeScreenshot() async {
    return await _channel.invokeMethod('takeScreenshot');
  }

  /// dump UI 层级
  static Future<Map<dynamic, dynamic>> dumpUi() async {
    return await _channel.invokeMethod('dumpUi');
  }

  /// 点击
  static Future<Map<dynamic, dynamic>> tap(int x, int y) async {
    return await _channel.invokeMethod('tap', {'x': x, 'y': y});
  }

  /// 滑动
  static Future<Map<dynamic, dynamic>> swipe(int x1, int y1, int x2, int y2,
      {int durationMs = 300}) async {
    return await _channel.invokeMethod('swipe', {
      'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'durationMs': durationMs
    });
  }

  /// 输入文本
  static Future<Map<dynamic, dynamic>> inputText(String text) async {
    return await _channel.invokeMethod('inputText', {'text': text});
  }
}
