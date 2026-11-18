# Lots Markdown agent guide

## Ownership

- `core/`: back-end coder (Rust core and UniFFI bindings).
- `apps/`, `themes/`, `bench/`: front-end coder.
- Edit outside your area only after the owner agrees.

## Renderer contract (core `render_html`, and the temporary `apps/render-stub`)

- Input: UTF-8 Markdown. Output: an HTML fragment, not a page.
- Every block element carries `data-src-start` / `data-src-end`: a half-open UTF-8 byte range over the original input, including the block's Markdown syntax. No newline or Unicode normalization. Nested blocks carry their own range; fenced code is marked on `<pre>`. Inline elements need no attributes.
- The document is untrusted. Raw HTML is shown as text, never executed. Links with script-capable schemes (`javascript:`, `vbscript:`, non-image `data:`, SVG `data:`) are neutralized. Shells also disable JavaScript in the preview and open links outside it.

## Rules

- Public repository: no Lolita names, private paths, keys or personal data in code, docs or commits.
- Performance claims cite `bench/` output with the machine and load average.
- Formats (`.lots`, `.lotspack`, sidecar) follow the published spec; do not invent fields.
