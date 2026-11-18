package com.lotsmemex.markdown

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ScrollView
import android.widget.TextView
import java.util.concurrent.Executors

/**
 * Stage 1 viewer. Top left: open file. Top right: 编辑 / 标注 / 渲染.
 * The source text shows first; the WebView is created after the first frame.
 */
class MainActivity : Activity() {
    private lateinit var root: FrameLayout
    private lateinit var source: TextView
    private lateinit var sourceScroll: ScrollView
    private var web: WebView? = null
    private var bytes = ByteArray(0)
    private var mode = MODE_RENDER
    private val worker = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        source = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            textSize = 13f
            setTextIsSelectable(true)
            setPadding(32, 32, 32, 32)
        }
        sourceScroll = ScrollView(this).apply { addView(source) }
        root = FrameLayout(this).apply { addView(sourceScroll) }
        setContentView(root)
        actionBar?.setDisplayHomeAsUpEnabled(true)
        actionBar?.setHomeAsUpIndicator(android.R.drawable.ic_menu_sort_by_size)
        intent?.data?.let(::open)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.let(::open)
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menu.add(0, MODE_EDIT, 0, "编辑").setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
        menu.add(0, MODE_ANNOTATE, 1, "标注").setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS).isEnabled = false
        menu.add(0, MODE_RENDER, 2, "渲染").setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        when (item.itemId) {
            android.R.id.home -> pickFile()
            MODE_EDIT -> { mode = MODE_EDIT; web?.visibility = View.GONE; sourceScroll.visibility = View.VISIBLE }
            MODE_RENDER -> { mode = MODE_RENDER; render() }
            else -> return super.onOptionsItemSelected(item)
        }
        return true
    }

    private fun pickFile() {
        val pick = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/markdown", "text/x-markdown", "text/plain"))
        }
        startActivityForResult(pick, REQUEST_OPEN)
    }

    @Deprecated("Activity result API needs AndroidX; this shell stays dependency-free.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_OPEN && resultCode == RESULT_OK) data?.data?.let(::open)
    }

    private fun open(uri: Uri) {
        val opened = SystemClock.elapsedRealtime()
        bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return
        title = uri.lastPathSegment?.substringAfterLast('/') ?: "Markdown"
        source.text = String(bytes, Charsets.UTF_8)
        web?.visibility = View.GONE
        sourceScroll.visibility = View.VISIBLE
        root.post {
            bench("first_frame", "\"file_bytes\":${bytes.size},\"open_to_frame_ms\":${SystemClock.elapsedRealtime() - opened}")
            if (mode == MODE_RENDER) render()
        }
    }

    private fun render() {
        val view = web ?: makeWebView()
        val input = bytes
        val started = SystemClock.elapsedRealtime()
        worker.execute {
            val body = String(Renderer.renderHtml(input), Charsets.UTF_8)
            val renderMs = SystemClock.elapsedRealtime() - started
            val page = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><style>$CSS</style><body>$body</body>"
            runOnUiThread {
                bench("rendered", "\"render_ms\":$renderMs")
                view.loadDataWithBaseURL(null, page, "text/html", "utf-8", null)
            }
        }
    }

    private fun makeWebView(): WebView {
        val view = WebView(this)
        // The document is untrusted: no scripts, no file access, links open outside.
        view.settings.javaScriptEnabled = false
        view.settings.allowFileAccess = false
        view.settings.allowContentAccess = false
        view.visibility = View.GONE
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                val url = request.url
                if (url.scheme in setOf("http", "https", "mailto")) {
                    runCatching { startActivity(Intent(Intent.ACTION_VIEW, url)) }
                }
                return true
            }

            override fun onPageFinished(v: WebView, url: String?) {
                if (mode != MODE_RENDER) return
                v.visibility = View.VISIBLE
                sourceScroll.visibility = View.GONE
                bench("preview_ready", "")
            }
        }
        root.addView(view)
        web = view
        return view
    }

    private fun bench(event: String, fields: String) {
        val sep = if (fields.isEmpty()) "" else ","
        Log.i("LotsBench", "{\"event\":\"$event\"$sep$fields,\"uptime_ms\":${SystemClock.uptimeMillis()}}")
    }

    companion object {
        const val MODE_EDIT = 1
        const val MODE_ANNOTATE = 2
        const val MODE_RENDER = 3
        const val REQUEST_OPEN = 10
        const val CSS = """
:root { color-scheme: light dark; }
body { font: 17px/1.75 sans-serif; margin: 1em 1.1em 3em; }
pre, code { font: 13px/1.5 monospace; }
pre { padding: .8em 1em; overflow: auto; background: rgba(127,127,127,.12); border-radius: 6px; }
table { border-collapse: collapse; display: block; overflow-x: auto; } th, td { border: 1px solid rgba(127,127,127,.35); padding: .3em .6em; }
img { max-width: 100%; } blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid rgba(127,127,127,.4); }
.lm-raw-html { white-space: pre-wrap; font: 13px/1.5 monospace; opacity: .7; }
"""
    }
}
