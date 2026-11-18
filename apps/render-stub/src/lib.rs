//! Temporary stub so the shells can show a preview before `core/` ships its FFI.
//! Delete once the core crate exports `render_html`.
//!
//! Contract (shared with core/): returns an HTML fragment, not a page. Every block element
//! carries `data-src-start` / `data-src-end`: the half-open UTF-8 byte range in the input,
//! including the block's Markdown syntax; nested blocks each carry their own range; fenced
//! code is marked on `<pre>`. Tables and footnote definitions are wrapped in a marked `<div>`.
//! Raw HTML from the document is shown as text, never executed, and links with script-capable
//! schemes are neutralized.

use pulldown_cmark::{html, CodeBlockKind, CowStr, Event, Options, Parser, Tag};
use std::ffi::c_char;
use std::fmt::Write;

fn options() -> Options {
    Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
}

fn escape_attr(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    pulldown_cmark_escape::escape_html(&mut out, value).ok();
    out
}

fn safe_url(url: CowStr<'_>, image: bool) -> CowStr<'_> {
    let lower = url.trim_start().to_ascii_lowercase();
    let scheme_end = lower.find(':');
    let has_scheme = scheme_end.is_some_and(|i| lower[..i].chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c)));
    if !has_scheme {
        return url; // relative path or fragment
    }
    let allowed = ["http:", "https:", "mailto:"].iter().any(|s| lower.starts_with(s))
        || (image && lower.starts_with("data:image/") && !lower.starts_with("data:image/svg"));
    if allowed { url } else { CowStr::Borrowed("#") }
}

pub fn render_html(markdown: &str) -> String {
    let mut events: Vec<Event<'_>> = Vec::new();
    let mut closers: Vec<Option<&'static str>> = Vec::new();
    for (event, range) in Parser::new_ext(markdown, options()).into_offset_iter() {
        let src = format!(r#" data-src-start="{}" data-src-end="{}""#, range.start, range.end);
        match event {
            Event::Start(tag) => {
                let mut open = String::new();
                let mut close: Option<&'static str> = None;
                let keep = match tag {
                    Tag::Paragraph => { write!(open, "<p{src}>").ok(); None }
                    Tag::Heading { level, id, .. } => {
                        let id = id.map(|i| format!(r#" id="{}""#, escape_attr(&i))).unwrap_or_default();
                        write!(open, "<{level}{id}{src}>").ok();
                        None
                    }
                    Tag::BlockQuote(_) => { write!(open, "<blockquote{src}>").ok(); None }
                    Tag::CodeBlock(kind) => {
                        let lang = match &kind {
                            CodeBlockKind::Fenced(info) => info.split_whitespace().next().unwrap_or(""),
                            CodeBlockKind::Indented => "",
                        };
                        let class = if lang.is_empty() { String::new() } else { format!(r#" class="language-{}""#, escape_attr(lang)) };
                        write!(open, "<pre{src}><code{class}>").ok();
                        None
                    }
                    Tag::List(Some(1)) => { write!(open, "<ol{src}>").ok(); None }
                    Tag::List(Some(n)) => { write!(open, r#"<ol start="{n}"{src}>"#).ok(); None }
                    Tag::List(None) => { write!(open, "<ul{src}>").ok(); None }
                    Tag::Item => { write!(open, "<li{src}>").ok(); None }
                    Tag::HtmlBlock => { write!(open, r#"<div class="lm-raw-html"{src}>"#).ok(); close = Some("</div>\n"); None }
                    Tag::Table(_) | Tag::FootnoteDefinition(_) => {
                        write!(open, r#"<div class="lm-block"{src}>"#).ok();
                        close = Some("</div>\n");
                        Some(tag)
                    }
                    Tag::Link { link_type, dest_url, title, id } => Some(Tag::Link { link_type, dest_url: safe_url(dest_url, false), title, id }),
                    Tag::Image { link_type, dest_url, title, id } => Some(Tag::Image { link_type, dest_url: safe_url(dest_url, true), title, id }),
                    other => Some(other),
                };
                if !open.is_empty() { events.push(Event::Html(open.into())); }
                if let Some(tag) = keep { events.push(Event::Start(tag)); }
                closers.push(close);
            }
            Event::End(end) => {
                let close = closers.pop().flatten();
                if !matches!(end, pulldown_cmark::TagEnd::HtmlBlock) { events.push(Event::End(end)); }
                if let Some(close) = close { events.push(Event::Html(close.into())); }
            }
            // Document HTML is shown as text, never parsed by the WebView.
            Event::Html(raw) | Event::InlineHtml(raw) => events.push(Event::Text(raw)),
            other => events.push(other),
        }
    }
    let mut out = String::with_capacity(markdown.len() * 3 / 2);
    html::push_html(&mut out, events.into_iter());
    out
}

/// Renders UTF-8 Markdown (`len` bytes at `ptr`) to a NUL-terminated HTML fragment.
/// Invalid UTF-8 is replaced (offsets then refer to the replaced text). Free with `lm_free`.
///
/// # Safety
/// `ptr` must point to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn lm_render_html(ptr: *const u8, len: usize) -> *mut c_char {
    let bytes = std::slice::from_raw_parts(ptr, len);
    let mut out = render_html(&String::from_utf8_lossy(bytes)).into_bytes();
    out.retain(|b| *b != 0);
    out.push(0);
    Box::into_raw(out.into_boxed_slice()) as *mut c_char
}

/// Frees a string returned by `lm_render_html`.
///
/// # Safety
/// `ptr` must come from `lm_render_html` and not be freed twice.
#[no_mangle]
pub unsafe extern "C" fn lm_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    let len = std::ffi::CStr::from_ptr(ptr).to_bytes_with_nul().len();
    drop(Box::from_raw(std::slice::from_raw_parts_mut(ptr as *mut u8, len)));
}

/// Android entry point: `Renderer.renderHtml(ByteArray): ByteArray` (UTF-8 in, UTF-8 out).
#[cfg(feature = "jni")]
#[no_mangle]
pub extern "system" fn Java_com_lotsmemex_markdown_Renderer_renderHtml<'a>(
    env: jni::JNIEnv<'a>,
    _class: jni::objects::JClass<'a>,
    input: jni::objects::JByteArray<'a>,
) -> jni::objects::JByteArray<'a> {
    let bytes = env.convert_byte_array(&input).unwrap_or_default();
    let html = render_html(&String::from_utf8_lossy(&bytes));
    env.byte_array_from_slice(html.as_bytes()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::render_html;

    /// Extracts (tag, start, end) for every marked element.
    fn marks(html: &str) -> Vec<(String, usize, usize)> {
        let mut out = Vec::new();
        for part in html.split('<').skip(1) {
            let Some(s) = part.find("data-src-start=\"") else { continue };
            let tag: String = part.chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
            let rest = &part[s + 16..];
            let start: usize = rest[..rest.find('"').unwrap()].parse().unwrap();
            let e = rest.find("data-src-end=\"").unwrap() + 14;
            let end: usize = rest[e..e + rest[e..].find('"').unwrap()].parse().unwrap();
            out.push((tag, start, end));
        }
        out
    }

    #[test]
    fn block_ranges_are_utf8_byte_ranges_over_the_input() {
        let md = "# 标题\r\n\n中文段落 **粗**\n\n> 引用\n> - 项\n\n```rust\nfn main() {}\n```\n";
        let html = render_html(md);
        for (tag, start, end) in marks(&html) {
            assert!(md.is_char_boundary(start) && md.is_char_boundary(end), "{tag} {start}..{end}");
            let slice = &md[start..end];
            match tag.as_str() {
                "h1" => assert!(slice.starts_with("# 标题")),
                "p" if slice.contains("中文") => assert_eq!(slice.trim_end(), "中文段落 **粗**"),
                "blockquote" => assert!(slice.starts_with("> 引用")),
                "li" => assert!(slice.contains("项")),
                "pre" => assert!(slice.starts_with("```rust") && slice.trim_end().ends_with("```")),
                _ => {}
            }
        }
        let tags: Vec<_> = marks(&html).into_iter().map(|m| m.0).collect();
        for t in ["h1", "p", "blockquote", "ul", "li", "pre"] { assert!(tags.iter().any(|x| x == t), "{t} in {tags:?}"); }
    }

    #[test]
    fn document_html_and_script_links_are_inert() {
        let html = render_html("<script>alert(1)</script>\n\nx <img src=x onerror=alert(1)> [a](javascript:alert(1)) [b](JaVaScRiPt:x) ![i](data:image/svg+xml,<svg>) [ok](./a.md) [w](https://e.com)\n");
        assert!(!html.contains("<script") && !html.contains("<img src=x"));
        assert!(!html.to_ascii_lowercase().contains("javascript:"));
        assert!(!html.contains("data:image/svg"));
        assert!(html.contains(r#"href="./a.md""#) && html.contains(r#"href="https://e.com""#));
    }
}
