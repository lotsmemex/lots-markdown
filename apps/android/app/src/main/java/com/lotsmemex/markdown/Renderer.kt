package com.lotsmemex.markdown

/** Temporary JNI bridge to apps/render-stub until core/ ships UniFFI bindings. */
object Renderer {
    init { System.loadLibrary("lots_render_stub") }

    @JvmStatic external fun renderHtml(markdown: ByteArray): ByteArray
}
