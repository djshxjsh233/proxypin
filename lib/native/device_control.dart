import 'package:flutter/services.dart';

/// 设备控制(原生通道): shell / 启动App / 截图 / UI控制
class DeviceControl {
  static const MethodChannel _channel = MethodChannel('com.proxy/deviceControl');

  /// 执行 shell 命令 (优先 su, 回退 sh)
  static Future<Map<dynamic, dynamic>> runShell(String command) async {
    return await _channel.invokeMethod('runShell', {'command': command});
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
