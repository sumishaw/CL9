package com.example.nihongolens

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Build
import kotlinx.coroutines.*
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.sqrt

/**
 * BackgroundMusicRecorder — dedicated channel for capturing background audio.
 *
 * ARCHITECTURE:
 *   - Separate AudioRecord at 44100Hz stereo (full quality, separate from GenderAnalyzer)
 *   - Energy gate: only captures when RMS > SILENCE_THRESHOLD (no silence noise)
 *   - Collects audio in 2-second chunks tagged with sequence numbers
 *   - Each chunk POSTed to /bg on TTS server (indexed FIFO buffer)
 *   - HindiTtsService snapshots current bgSeq at speak() time
 *   - Server mixes that exact chunk into the TTS WAV for perfect timing
 *
 * TIMING ALIGNMENT:
 *   Sentence arrives at t=0 → bgSeq=42 captured
 *   Translation takes 2s → TTS fires at t=2s with bg_seq=42
 *   Server retrieves chunk #42 (the audio from t=0) → perfect match
 */
object BackgroundMusicRecorder {

    private const val TAG            = "BGMusic"
    private const val SR             = 44100
    private const val CHANNELS       = AudioFormat.CHANNEL_IN_STEREO
    private const val CHANNEL_COUNT  = 2
    private const val CHUNK_MS       = 2000L          // 2-second chunks
    private const val CHUNK_SAMPLES  = (SR * CHUNK_MS / 1000).toInt() * CHANNEL_COUNT
    private const val SILENCE_RMS    = 150f           // below = silence, skip
    private const val SERVER_URL     = "http://127.0.0.1:8766/bg"
    private const val MAX_STORED     = 30             // keep last 30 chunks (~60s)

    // Current background sequence number — snapshot this at sentence enqueue time
    val currentSeq = AtomicInteger(0)

    // FIX BUG 2: Local indexed chunk store for Android-side BG mixing.
    // HindiTtsService.mixBgMusic() reads from here — no server round-trip needed.
    // Key=seq, Value=raw int16 PCM bytes (44100Hz stereo)
    private val chunkStore   = ConcurrentHashMap<Int, ByteArray>()
    private val chunkSeqList = ArrayDeque<Int>()
    private val chunkLock    = Any()

    fun getChunk(seq: Int): ByteArray? {
        // Try exact seq first, then nearby (±3 = ±6s tolerance)
        return chunkStore[seq]
            ?: chunkStore[seq - 1] ?: chunkStore[seq + 1]
            ?: chunkStore[seq - 2] ?: chunkStore[seq + 2]
            ?: chunkStore[seq - 3] ?: chunkStore[seq + 3]
    }

    private val scope       = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var captureJob: Job? = null
    private var captureRec: AudioRecord? = null

    @Volatile var enabled   = false

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    fun start(projection: MediaProjection?) {
        if (enabled || projection == null) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        stop()
        captureJob = scope.launch { captureLoop(projection) }
    }

    fun stop() {
        enabled = false
        captureJob?.cancel(); captureJob = null
        try { captureRec?.stop()    } catch (_: Exception) {}
        try { captureRec?.release() } catch (_: Exception) {}
        captureRec = null
        CaptionLogger.log(TAG, "stopped")
    }

    // ── USAGE_MEDIA capture at 44100Hz stereo ─────────────────────────────────

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.Q)
    private suspend fun captureLoop(projection: MediaProjection) = withContext(Dispatchers.IO) {
        val config = try {
            AudioPlaybackCaptureConfiguration.Builder(projection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .build()
        } catch (e: Exception) {
            CaptionLogger.log(TAG, "config failed: ${e.message}"); return@withContext
        }

        val minBuf = AudioRecord.getMinBufferSize(SR, CHANNELS,
            AudioFormat.ENCODING_PCM_16BIT).coerceAtLeast(CHUNK_SAMPLES * 2)

        val rec = try {
            AudioRecord.Builder()
                .setAudioFormat(AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SR)
                    .setChannelMask(CHANNELS)
                    .build())
                .setBufferSizeInBytes(minBuf)
                .setAudioPlaybackCaptureConfig(config)
                .build()
        } catch (e: Exception) {
            CaptionLogger.log(TAG, "AudioRecord failed: ${e.message}"); return@withContext
        }

        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); return@withContext }

        captureRec = rec; enabled = true
        rec.startRecording()
        CaptionLogger.log(TAG, "BG capture started SR=${SR}Hz stereo (dedicated channel)")

        val chunkBuf  = ShortArray(CHUNK_SAMPLES)
        val readBuf   = ByteArray(minBuf)
        val collector = ByteArrayOutputStream()
        var samplesCollected = 0

        try {
            while (currentCoroutineContext().isActive && enabled) {
                val bytesRead = rec.read(readBuf, 0, readBuf.size.coerceAtMost(CHUNK_SAMPLES * 2))
                if (bytesRead <= 0) continue

                collector.write(readBuf, 0, bytesRead)
                samplesCollected += bytesRead / 2  // bytes → samples (16-bit)

                // When we have a full 2-second chunk, process it
                if (samplesCollected >= CHUNK_SAMPLES) {
                    val pcmBytes = collector.toByteArray()
                    collector.reset()
                    samplesCollected = 0

                    // Energy gate: measure RMS to skip silence
                    val rms = calcRms(pcmBytes)
                    if (rms > SILENCE_RMS) {
                        val seq = currentSeq.incrementAndGet()
                        // Store locally for Android-side mixing (HindiTtsService.mixBgMusic)
                        synchronized(chunkLock) {
                            chunkStore[seq] = pcmBytes
                            chunkSeqList.addLast(seq)
                            if (chunkSeqList.size > MAX_STORED) {
                                chunkStore.remove(chunkSeqList.removeFirst())
                            }
                        }
                        // Also POST to server for server-side mixing fallback
                        launch(Dispatchers.IO) {
                            sendChunk(seq, pcmBytes)
                        }
                    } else {
                        currentSeq.incrementAndGet()
                    }
                }
            }
        } finally {
            try { rec.stop(); rec.release() } catch (_: Exception) {}
            captureRec = null; enabled = false
            CaptionLogger.log(TAG, "BG capture ended")
        }
    }

    // ── RMS energy calculation ─────────────────────────────────────────────────

    private fun calcRms(bytes: ByteArray): Float {
        var energy = 0.0
        var i = 0
        val count = (bytes.size / 2).coerceAtMost(4096) // sample first 4096 frames
        while (i < count * 2 && i + 1 < bytes.size) {
            val sample = ((bytes[i + 1].toInt() shl 8) or (bytes[i].toInt() and 0xFF)).toShort()
            energy += sample.toLong() * sample
            i += 2
        }
        return sqrt(energy / count).toFloat()
    }

    // ── POST chunk to server ───────────────────────────────────────────────────

    private fun sendChunk(seq: Int, pcmBytes: ByteArray) {
        try {
            val conn = URL("$SERVER_URL?seq=$seq&sr=$SR&ch=$CHANNEL_COUNT")
                .openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.doOutput      = true
            conn.connectTimeout = 500
            conn.readTimeout    = 500
            conn.setRequestProperty("Content-Type",   "application/octet-stream")
            conn.setRequestProperty("Content-Length", pcmBytes.size.toString())
            conn.outputStream.use { it.write(pcmBytes) }
            val code = conn.responseCode
            conn.disconnect()
            if (code == 200)
                CaptionLogger.log(TAG, "chunk #$seq sent ${pcmBytes.size/1024}KB rms>$SILENCE_RMS")
        } catch (_: Exception) {
            // Best-effort — never block TTS pipeline
        }
    }
}
