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
                        val useSu = call.argument<Boolean>("use_su") ?: true
                        Thread {
                            val r: Map<String, Any?> = runShell(cmd, useSu)
                            result.success(r)
                        }.start()
                    }
                    "sqliteQuery" -> {
                        val dbPath = call.argument<String>("dbPath") ?: ""
                        val query = call.argument<String>("query") ?: ""
                        Thread {
                            val r: Map<String, Any?> = sqliteQuery(dbPath, query)
                            result.success(r)
                        }.start()
                    }
                    "readFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        Thread {
                            val r: Map<String, Any?> = readFile(path)
                            result.success(r)
                        }.start()
                    }
                    "readFileChunk" -> {
                        val path = call.argument<String>("path") ?: ""
                        // Dart int 可能映射为 Integer, 用 Number 兼容
                        val offset = (call.argument<Number>("offset") ?: 0L).toLong()
                        val chunkSize = (call.argument<Number>("chunkSize") ?: 65536L).toLong()
                        Thread {
                            val r: Map<String, Any?> = readFileChunk(path, offset, chunkSize)
                            result.success(r)
                        }.start()
                    }
                    "listDir" -> {
                        val path = call.argument<String>("path") ?: ""
                        Thread {
                            val r: Map<String, Any?> = listDir(path)
                            result.success(r)
                        }.start()
                    }
                    "writeFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        val content = call.argument<String>("content") ?: ""
                        Thread {
                            val r: Map<String, Any?> = writeFile(path, content)
                            result.success(r)
                        }.start()
                    }
                    "copyFile" -> {
                        val src = call.argument<String>("src") ?: ""
                        val dst = call.argument<String>("dst") ?: ""
                        Thread {
                            val r: Map<String, Any?> = copyFile(src, dst)
                            result.success(r)
                        }.start()
                    }
                    "moveFile" -> {
                        val src = call.argument<String>("src") ?: ""
                        val dst = call.argument<String>("dst") ?: ""
                        Thread {
                            val r: Map<String, Any?> = moveFile(src, dst)
                            result.success(r)
                        }.start()
                    }
                    "deleteFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        Thread {
                            val r: Map<String, Any?> = deleteFile(path)
                            result.success(r)
                        }.start()
                    }
                    "getForegroundActivity" -> {
                        Thread {
                            val r: Map<String, Any?> = runShell("dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' | head -3", true)
                            result.success(r)
                        }.start()
                    }
                    "logcat" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        val lines = call.argument<Int>("lines") ?: 200
                        val clear = call.argument<Boolean>("clear") ?: false
                        Thread {
                            val r: Map<String, Any?> = logcat(pkg, lines, clear)
                            result.success(r)
                        }.start()
                    }
                    "launchApp" -> {
                        val pkg = call.argument<String>("packageName") ?: ""
                        result.success(launchApp(pkg))
                    }
                    "takeScreenshot" -> {
                        Thread {
                            val r: Map<String, Any?> = takeScreenshot()
                            result.success(r)
                        }.start()
                    }
                    "dumpUi" -> {
                        Thread {
                            val r: Map<String, Any?> = runShell("uiautomator dump /sdcard/window_dump.xml && cat /sdcard/window_dump.xml")
                            result.success(r)
                        }.start()
                    }
                    "tap" -> {
                        val x = call.argument<Int>("x") ?: 0
                        val y = call.argument<Int>("y") ?: 0
                        Thread {
                            val r: Map<String, Any?> = runShell("input tap $x $y")
                            result.success(r)
                        }.start()
                    }
                    "swipe" -> {
                        val x1 = call.argument<Int>("x1") ?: 0
                        val y1 = call.argument<Int>("y1") ?: 0
                        val x2 = call.argument<Int>("x2") ?: 0
                        val y2 = call.argument<Int>("y2") ?: 0
                        val dur = call.argument<Int>("durationMs") ?: 300
                        Thread {
                            val r: Map<String, Any?> = runShell("input swipe $x1 $y1 $x2 $y2 $dur")
                            result.success(r)
                        }.start()
                    }
                    "inputText" -> {
                        val text = call.argument<String>("text") ?: ""
                        Thread {
                            val cmd = "input text ${escapeShell(text)}"
                            val r: Map<String, Any?> = runShell(cmd)
                            result.success(r)
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("DEVICE_CTRL_ERROR", e.message, null)
            }
        }
    }

    /** 执行 shell 命令(默认优先 su root, useSu=false 时用 sh) */
    private fun runShell(command: String, useSu: Boolean = true): Map<String, Any?> {
        // 尝试 su; 失败回退 sh
        if (useSu) {
            try {
                val p = Runtime.getRuntime().exec(arrayOf("su", "-c", command))
                val output = p.inputStream.bufferedReader().readText()
                val err = p.errorStream.bufferedReader().readText()
                val code = p.waitFor()
                // su 进程存在但命令失败时也返回, 让上层决定是否回退
                return mapOf(
                    "exitCode" to code,
                    "stdout" to output,
                    "stderr" to err,
                    "usedSu" to true
                )
            } catch (e: Exception) {
                // su 不可用, 落到 sh
            }
        }
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("sh", "-c", command))
            val output = p.inputStream.bufferedReader().readText()
            val err = p.errorStream.bufferedReader().readText()
            val code = p.waitFor()
            mapOf("exitCode" to code, "stdout" to output, "stderr" to err, "usedSu" to false)
        } catch (e2: Exception) {
            mapOf("exitCode" to -1, "stdout" to "", "stderr" to (e2.message ?: ""), "usedSu" to false)
        }
    }

    /** 查询私有 sqlite 数据库(root 必须) */
    private fun sqliteQuery(dbPath: String, query: String): Map<String, Any?> {
        // 找设备上的 sqlite3(常见路径)
        val sqlite3 = arrayOf(
            "/system/bin/sqlite3", "/system/xbin/sqlite3",
            "/data/adb/modules/sqlite3/sqlite3", "/data/data/com.termux/files/usr/bin/sqlite3"
        ).firstOrNull { File(it).exists() } ?: "sqlite3"
        val cmd = "$sqlite3 \"$dbPath\" \"$query\""
        return runShell(cmd, useSu = true)
    }

    /** 读取文件内容(root 读 /data/data 私有文件) */
    private fun readFile(path: String): Map<String, Any?> {
        val r = runShell("cat \"$path\"", useSu = true)
        return r
    }

    /** 分块读取文件(root): 从 offset 起读 chunkSize 字节, base64 返回 */
    private fun readFileChunk(path: String, offset: Long, chunkSize: Long): Map<String, Any?> {
        // dd 按偏移读指定字节, base64 编码输出
        return runShell(
            "dd if=\"$path\" bs=1 skip=$offset count=$chunkSize 2>/dev/null | base64 -w 0",
            useSu = true
        )
    }

    /** 列出目录内容(root 可看 /data) */
    private fun listDir(path: String): Map<String, Any?> {
        return runShell("ls -la \"$path\"", useSu = true)
    }

    /** 写文件(root, 可写 /data) */
    private fun writeFile(path: String, content: String): Map<String, Any?> {
        // 用 base64 传输避免转义问题
        val b64 = Base64.encodeToString(content.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        return runShell("echo \"$b64\" | base64 -d > \"$path\"", useSu = true)
    }

    /** 复制文件(跨目录, root) */
    private fun copyFile(src: String, dst: String): Map<String, Any?> {
        return runShell("cp -rf \"$src\" \"$dst\" && chmod -R 777 \"$dst\" 2>/dev/null; echo COPY_OK", useSu = true)
    }

    /** 移动文件(跨目录, root) */
    private fun moveFile(src: String, dst: String): Map<String, Any?> {
        return runShell("mv -f \"$src\" \"$dst\" 2>/dev/null || (cp -rf \"$src\" \"$dst\" && rm -rf \"$src\"); echo MOVE_OK", useSu = true)
    }

    /** 删除文件/目录(root) */
    private fun deleteFile(path: String): Map<String, Any?> {
        return runShell("rm -rf \"$path\" && echo DELETE_OK", useSu = true)
    }

    /** logcat 抓日志 */
    private fun logcat(pkg: String, lines: Int, clear: Boolean): Map<String, Any?> {
        val clearCmd = if (clear) "logcat -c; " else ""
        val filter = if (pkg.isNotEmpty()) " | grep -i \"$pkg\"" else ""
        val cmd = "${clearCmd}logcat -d -t $lines$filter"
        return runShell(cmd, useSu = false)
    }

    private fun launchApp(packageName: String): Boolean {
        // 主路径: cmd package resolve-activity 查真实入口 → am start -n
        // (getLaunchIntentForPackage 在部分 App(央视频) 上 intent 无效/不切前台, 弃用)
        try {
            val resolve = runShell(
                "/system/bin/cmd package resolve-activity --brief -c android.intent.category.LAUNCHER \"$packageName\" 2>/dev/null | tail -1",
                useSu = true
            )
            val entry = (resolve["stdout"] as String? ?: "").trim()
            if (entry.isNotEmpty() && entry.contains("/")) {
                // 用全路径 am, 避免 Kotlin sh 环境 PATH 不全(不依赖 \$PATH 插值)
                val start = runShell("/system/bin/am start -n \"$entry\" 2>&1", useSu = false)
                val out = start["stdout"] as String? ?: ""
                return out.contains("Starting:") || out.contains("Warning")
            }
        } catch (e: Exception) {
            // ignore
        }
        // 兜底: getLaunchIntentForPackage
        try {
            val pm = activity.packageManager
            val intent = pm.getLaunchIntentForPackage(packageName)
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                activity.startActivity(intent)
                return true
            }
        } catch (e: Exception) {
            // ignore
        }
        return false
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
