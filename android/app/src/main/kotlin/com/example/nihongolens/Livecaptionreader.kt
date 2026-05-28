package com.example.nihongolens

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import kotlinx.coroutines.*
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.LinkedBlockingQueue

/**
 * LiveCaptionReader v5 — Confirmed package: com.google.android.as
 *
 * Live Captions on this device (Lenovo Tab P12, Android 15) runs in:
 *   com.google.android.as  (Android System Intelligence)
 *
 * This version uses a TWO-TRACK approach:
 * Track A: Direct event text from com.google.android.as events
 * Track B: Full tree scan of com.google.android.as window nodes
 *
 * Both tracks run on every event from com.google.android.as.
 * First non-empty result wins.
 */
class LiveCaptionReader : AccessibilityService() {

    companion object {
        private const val TAG = "LiveCaptionReader"

        // Confirmed package on this device
        private const val LIVE_CAPTION_PKG = "com.google.android.as"

        // Also monitor TTS package as fallback
        private val MONITOR_PACKAGES = arrayOf(
            "com.google.android.as",
            "com.google.android.as.oss",
            "com.google.android.tts",
        )

        private const val TRANSLATE_URL   = "http://127.0.0.1:8765/translate_text"
        private const val CONNECT_TIMEOUT = 2_000
        private const val READ_TIMEOUT    = 12_000
        private const val DEBOUNCE_MS     = 350L

        @Volatile var isRunning       = false
        @Volatile var lastCaptionText = ""
        @Volatile var instance: LiveCaptionReader? = null
    }

    private val scope         = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var pendingJob:    Job? = null
    private var translateJob:  Job? = null
    private var lastSentText   = ""
    private var lastHindiOut   = ""
    private val translateQueue = LinkedBlockingQueue<String>(8)

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance  = this
        isRunning = true

        serviceInfo = serviceInfo?.also { info ->
            info.eventTypes = (
                AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or
                AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED or
                AccessibilityEvent.TYPE_WINDOWS_CHANGED
            )
            info.feedbackType        = AccessibilityServiceInfo.FEEDBACK_GENERIC
            info.notificationTimeout = 50
            info.flags               = (
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            )
            // Only monitor confirmed Live Captions packages
            info.packageNames = MONITOR_PACKAGES
        }

        startTranslateWorker()
        Log.i(TAG, "LiveCaptionReader v5 connected — pkg=$LIVE_CAPTION_PKG")
        scope.launch(Dispatchers.Main) {
            MainActivity.instance?.onLiveCaptionReaderConnected()
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (!isRunning || event == null) return

        val pkg = event.packageName?.toString() ?: return
        if (pkg !in MONITOR_PACKAGES) return

        Log.v(TAG, "Event from $pkg type=${event.eventType}")

        // Track A: direct event text (fastest)
        val directText = event.text
            ?.mapNotNull { it?.toString()?.trim() }
            ?.filter { it.length >= 3 }
            ?.joinToString(" ")
            ?.trim()

        if (!directText.isNullOrBlank() && isValidCaption(directText)) {
            Log.d(TAG, "Track A: $directText")
            onCaptionFound(directText)
            return
        }

        // Track B: full tree scan of the window
        val root = try { rootInActiveWindow } catch (_: Exception) { null } ?: return
        val treeText = scanTree(root)
        root.recycle()

        if (!treeText.isNullOrBlank()) {
            Log.d(TAG, "Track B: $treeText")
            onCaptionFound(treeText)
        }
    }

    // ── Tree scan ─────────────────────────────────────────────────────────────

    private fun scanTree(node: AccessibilityNodeInfo?): String? {
        node ?: return null

        val text   = node.text?.toString()?.trim() ?: ""
        val viewId = node.viewIdResourceName?.lowercase() ?: ""
        val cls    = node.className?.toString()?.lowercase() ?: ""

        // Priority 1: known caption view IDs
        if (listOf("caption_text", "captiontext", "live_caption_text",
                "transcript", "caption_window").any { viewId.contains(it) }
            && text.isNotBlank()) {
            return text
        }

        // Priority 2: any text view with valid speech text
        if (cls.contains("textview") && isValidCaption(text)) {
            return text
        }

        // Recurse
        for (i in 0 until node.childCount) {
            val found = scanTree(node.getChild(i))
            if (found != null) return found
        }
        return null
    }

    private fun isValidCaption(text: String): Boolean {
        if (text.length < 3 || text.length > 350) return false
        val letters = text.count { it.isLetter() }
        if (letters < text.length * 0.4) return false
        if (text.contains("http") || text.contains("www.")) return false
        if (text.contains("com.") || text.contains("android.")) return false
        return true
    }

    // ── Caption found ─────────────────────────────────────────────────────────

    private fun onCaptionFound(text: String) {
        if (text == lastCaptionText) return
        lastCaptionText = text
        scheduleTranslation(text)
    }

    // ── Debounce + queue ──────────────────────────────────────────────────────

    private fun scheduleTranslation(text: String) {
        pendingJob?.cancel()
        pendingJob = scope.launch {
            delay(DEBOUNCE_MS)
            if (text == lastCaptionText && text != lastSentText) {
                lastSentText = text
                if (translateQueue.size >= 8) translateQueue.poll()
                translateQueue.offer(text)
            }
        }
    }

    private fun startTranslateWorker() {
        translateJob = scope.launch {
            while (isActive) {
                val text = withContext(Dispatchers.IO) {
                    try { translateQueue.poll(2, java.util.concurrent.TimeUnit.SECONDS) }
                    catch (_: InterruptedException) { null }
                } ?: continue

                val hindi = translate(text) ?: continue
                if (hindi.isBlank() || hindi == lastHindiOut) continue
                lastHindiOut = hindi

                Log.i(TAG, "✓ [${text.take(40)}] → [${hindi.take(40)}]")
                SpeechCaptureService.latestHindi   = hindi
                SpeechCaptureService.latestEnglish = text

                withContext(Dispatchers.Main) {
                    OverlayService.updateText(text, hindi)
                    MainActivity.instance?.onTranslation(text, hindi, hindi)
                }
            }
        }
    }

    // ── HTTP translation ──────────────────────────────────────────────────────

    private fun translate(text: String): String? {
        var conn: HttpURLConnection? = null
        return try {
            conn = URL(TRANSLATE_URL).openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            conn.doOutput       = true
            conn.connectTimeout = CONNECT_TIMEOUT
            conn.readTimeout    = READ_TIMEOUT
            val body = """{"text":${JSONObject.quote(text)},"src":"en","tgt":"hi"}"""
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            if (conn.responseCode != 200) { Log.w(TAG, "HTTP ${conn.responseCode}"); return null }
            val resp = conn.inputStream.bufferedReader(Charsets.UTF_8).readText()
            JSONObject(resp).optString("text", "").trim().takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            Log.w(TAG, "Translate error: ${e.message}")
            null
        } finally {
            try { conn?.disconnect() } catch (_: Exception) {}
        }
    }

    override fun onInterrupt() { Log.w(TAG, "Interrupted") }

    override fun onDestroy() {
        isRunning = false; instance = null
        pendingJob?.cancel(); translateJob?.cancel(); scope.cancel()
        super.onDestroy()
    }
}
