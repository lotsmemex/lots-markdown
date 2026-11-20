//! Markdown → inert HTML fragments with offsets into the original UTF-8 input.

use pulldown_cmark::{html, Alignment, CodeBlockKind, CowStr, Event, Options, Parser, Tag, TagEnd};
use std::collections::HashMap;

uniffi::setup_scaffolding!();

/// Render CommonMark with tables, footnotes, strikethrough and task lists.
///
/// Block ranges include Markdown syntax and use original UTF-8 byte offsets,
/// not character or UTF-16 indices. Raw HTML is escaped and unsafe URLs become
/// `#`. The result contains no document wrapper or CSS. Call off the UI thread.
#[uniffi::export]
pub fn render_html(markdown: String) -> String {
    let options = Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS;
    let mut alignments = Vec::new();
    let mut table_range = String::new();
    let mut in_header = false;
    let mut column = 0;
    let mut footnotes = HashMap::new();

    // Keep events streaming; pulldown-cmark still owns escaping and inline HTML
    // generation (including image alt text). Only block tags need replacement.
    let events = Parser::new_ext(&markdown, options)
        .into_offset_iter()
        .map(|(event, range)| {
            let src = || {
                format!(
                    " data-src-start=\"{}\" data-src-end=\"{}\"",
                    range.start, range.end
                )
            };
            let markup = match event {
                Event::Start(tag) => match tag {
                    Tag::Paragraph => format!("<p{}>", src()),
                    Tag::Heading { level, .. } => format!("<{level}{}>", src()),
                    Tag::BlockQuote(_) => format!("<blockquote{}>\n", src()),
                    Tag::List(start) => match start {
                        Some(n) => format!("<ol start=\"{n}\"{}>\n", src()),
                        None => format!("<ul{}>\n", src()),
                    },
                    Tag::Item => format!("<li{}>", src()),
                    Tag::CodeBlock(kind) => {
                        let lang = match &kind {
                            CodeBlockKind::Fenced(info) => {
                                info.split_whitespace().next().unwrap_or("")
                            }
                            CodeBlockKind::Indented => "",
                        };
                        let class = if lang.is_empty() {
                            String::new()
                        } else {
                            format!(" class=\"language-{}\"", escape(lang))
                        };
                        format!("<pre{}><code{class}>", src())
                    }
                    Tag::HtmlBlock => format!("<div class=\"lm-raw-html\"{}>", src()),
                    Tag::Table(columns) => {
                        alignments = columns;
                        table_range = src();
                        format!("<table{table_range}>\n")
                    }
                    Tag::TableHead => {
                        in_header = true;
                        column = 0;
                        format!("<thead{}><tr{}>", src(), src())
                    }
                    Tag::TableRow => {
                        column = 0;
                        format!("<tr{}>", src())
                    }
                    Tag::TableCell => {
                        let tag = if in_header { "th" } else { "td" };
                        let style = match alignments.get(column) {
                            Some(Alignment::Left) => " style=\"text-align: left\"",
                            Some(Alignment::Center) => " style=\"text-align: center\"",
                            Some(Alignment::Right) => " style=\"text-align: right\"",
                            _ => "",
                        };
                        format!("<{tag}{}{style}>", src())
                    }
                    Tag::FootnoteDefinition(name) => {
                        let next = footnotes.len() + 1;
                        let number = *footnotes.entry(name.to_string()).or_insert(next);
                        format!(
                            "<div class=\"footnote-definition\" id=\"{}\"{}><sup class=\"footnote-definition-label\">{number}</sup>",
                            escape(&name), src()
                        )
                    }
                    Tag::Link { link_type, dest_url, title, id } => {
                        return Event::Start(Tag::Link {
                            link_type, dest_url: safe_url(dest_url, false), title, id,
                        });
                    }
                    Tag::Image { link_type, dest_url, title, id } => {
                        return Event::Start(Tag::Image {
                            link_type, dest_url: safe_url(dest_url, true), title, id,
                        });
                    }
                    other => return Event::Start(other),
                },
                Event::End(end) => match end {
                    TagEnd::Paragraph => "</p>\n".into(),
                    TagEnd::Heading(level) => format!("</{level}>\n"),
                    TagEnd::BlockQuote(_) => "</blockquote>\n".into(),
                    TagEnd::List(true) => "</ol>\n".into(),
                    TagEnd::List(false) => "</ul>\n".into(),
                    TagEnd::Item => "</li>\n".into(),
                    TagEnd::CodeBlock => "</code></pre>\n".into(),
                    TagEnd::HtmlBlock | TagEnd::FootnoteDefinition => "</div>\n".into(),
                    TagEnd::Table => "</tbody></table>\n".into(),
                    TagEnd::TableHead => {
                        in_header = false;
                        // tbody has no parser event; use the enclosing table's range.
                        format!("</tr></thead>\n<tbody{table_range}>\n")
                    }
                    TagEnd::TableRow => "</tr>\n".into(),
                    TagEnd::TableCell => {
                        column += 1;
                        if in_header { "</th>" } else { "</td>" }.into()
                    }
                    other => return Event::End(other),
                },
                Event::Rule => format!("<hr{} />\n", src()),
                Event::FootnoteReference(name) => {
                    let next = footnotes.len() + 1;
                    let number = *footnotes.entry(name.to_string()).or_insert(next);
                    format!("<sup class=\"footnote-reference\"><a href=\"#{}\">{number}</a></sup>", escape(&name))
                }
                Event::Html(raw) | Event::InlineHtml(raw) => return Event::Text(raw),
                other => return other,
            };
            Event::Html(markup.into())
        });
    let mut output = String::with_capacity(markdown.len());
    html::push_html(&mut output, events);
    output
}

fn escape(value: &str) -> String {
    let mut output = String::new();
    pulldown_cmark_escape::escape_html(&mut output, value).unwrap();
    output
}

fn safe_url(url: CowStr<'_>, image: bool) -> CowStr<'_> {
    // Browsers ignore tabs/newlines inside schemes and leading C0 controls.
    // Check that normalized form, not just the literal Markdown spelling.
    let normalized: String = url
        .chars()
        .filter(|c| !c.is_ascii_control() && !c.is_ascii_whitespace())
        .collect::<String>()
        .to_ascii_lowercase();
    let prefix = normalized.split(['/', '?', '#']).next().unwrap_or("");
    if !prefix.contains(':') {
        return url;
    }
    let allowed = normalized.starts_with("http:")
        || normalized.starts_with("https:")
        || (!image && normalized.starts_with("mailto:"))
        || (image
            && ["png", "jpeg", "gif", "webp", "avif", "bmp", "x-icon"]
                .iter()
                .any(|mime| normalized.starts_with(&format!("data:image/{mime};base64,"))));
    if allowed {
        url
    } else {
        CowStr::Borrowed("#")
    }
}
