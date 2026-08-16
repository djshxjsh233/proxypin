package com.network.proxy.plugin

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Environment
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * 设备控制插件: shell / 启动App / 截图 / UI控制
 *
 * @author mcp
 */
class DeviceControlPlugin : AndroidFlutterPlugin() {
    var channel: MethodChannel? = null

    companion object {
        const val CHANNEL = "com.proxy/deviceControl"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel!!.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "runShell" -> {
                        val cmd = call.argument<String>("command") ?: ""
                        Thread {
                            result.success(runShell(cmd))
                        }.start()
                    }
                    "launchApp" -> {
                        val pkg = call.argument<String>("packageName") ?: ""
                        result.success(launchApp(pkg))
                    }
                    "takeScreenshot" -> {
                        Thread {
                            result.success(takeScreenshot())
                        }.start()
                    }
                    "dumpUi" -> {
                        Thread {
                            result.success(runShell("uiautomator dump /sdcard/window_dump.xml && cat /sdcard/window_dump.xml"))
                        }.start()
                    }
                    "tap" -> {
                        val x = call.argument<Int>("x") ?: 0
                        val y = call.argument<Int>("y") ?: 0
                        Thread {
                            result.success(runShell("input tap $x $y"))
                        }.start()
                    }
                    "swipe" -> {
                        val x1 = call.argument<Int>("x1") ?: 0
                        val y1 = call.argument<Int>("y1") ?: 0
                        val x2 = call.argument<Int>("x2") ?: 0
                        val y2 = call.argument<Int>("y2") ?: 0
                        val dur = call.argument<Int>("durationMs") ?: 300
                        Thread {
                            result.success(runShell("input swipe $x1 $y1 $x2 $y2 $dur"))
                        }.start()
                    }
                    "inputText" -> {
                        val text = call.argument<String>("text") ?: ""
                        Thread {
                            result.success(runShell("input text ${escapeShell(text)}"))
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("DEVICE_CTRL_ERROR", e.message, null)
            }
        }
    }

    /** 执行 shell 命令(优先 su, 回退普通 sh) */
    private fun runShell(command: String): Map<String, Any?> {
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("su", "-c", command))
            val output = p.inputStream.bufferedReader().readText()
            val err = p.errorStream.bufferedReader().readText()
            val code = p.waitFor()
            mapOf(
                "exitCode" to code,
                "stdout" to output,
                "stderr" to err
            )
        } catch (e: Exception) {
            // su 不可用时回退
            try {
                val p = Runtime.getRuntime().exec(arrayOf("sh", "-c", command))
                val output = p.inputStream.bufferedReader().readText()
                val code = p.waitFor()
                mapOf(
                    "exitCode" to code,
                    "stdout" to output,
                    "stderr" to ""
                )
            } catch (e2: Exception) {
                mapOf("exitCode" to -1, "stdout" to "", "stderr" to e2.message ?: "")
            }
        }
    }

    private fun launchApp(packageName: String): Boolean {
        return try {
            val pm = activity.packageManager
            val intent = pm.getLaunchIntentForPackage(packageName)
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                activity.startActivity(intent)
                true
            } else {
                false
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun takeScreenshot(): Map<String, Any?> {
        return try {
            // 用 su screencap 截图(需要 root)
            val p = Runtime.getRuntime().exec(arrayOf("su", "-c", "screencap -p /data/local/tmp/mcp_shot.png"))
            p.waitFor()
            val file = File("/data/local/tmp/mcp_shot.png")
            if (file.exists() && file.length() > 0) {
                val bytes = file.readBytes()
                val b64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
                mapOf(
                    "success" to true,
                    "size" to bytes.size,
                    "base64" to b64,
                    "path" to file.absolutePath
                )
            } else {
                // 回退: 截当前 Activity 视图(无需 root)
                val view = activity.window.decorView
                val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
                view.draw(android.graphics.Canvas(bitmap))
                val out = File(activity.cacheDir, "mcp_shot.png")
                FileOutputStream(out).use { bitmap.compress(Bitmap.CompressFormat.PNG, 90, it) }
                val bytes = out.readBytes()
                mapOf(
                    "success" to true,
                    "size" to bytes.size,
                    "base64" to Base64.encodeToString(bytes, Base64.NO_WRAP),
                    "path" to out.absolutePath
                )
            }
        } catch (e: Exception) {
            mapOf("success" to false, "error" to (e.message ?: "unknown"))
        }
    }

    private fun escapeShell(s: String): String {
        return s.replace(" ", "%s").replace("&", "\\&").replace("|", "\\|")
            .replace(";", "\\;").replace("$", "\\$").replace("\"", "\\\"")
    }
}
