use lots_markdown_core::render_html;
use scraper::{ElementRef, Html, Selector};

fn select<'a>(doc: &'a Html, selector: &str) -> ElementRef<'a> {
    doc.select(&Selector::parse(selector).unwrap())
        .next()
        .unwrap()
}

fn source<'a>(node: ElementRef<'_>, markdown: &'a str) -> &'a str {
    let start = node
        .value()
        .attr("data-src-start")
        .unwrap()
        .parse()
        .unwrap();
    let end = node.value().attr("data-src-end").unwrap().parse().unwrap();
    &markdown[start..end]
}

#[test]
fn ranges_preserve_unicode_crlf_nested_blocks_and_fences() {
    let md = "# 中😀e\u{301}\r\n\r\n段落 **粗**\r\n\r\n> 引用\r\n> - 项\r\n\r\n7. 七\r\n8. 八\r\n\r\n```rust\r\n<x>&\r\n```\r\n\r\n---\r\n";
    let doc = Html::parse_fragment(&render_html(md.into()));
    for (selector, expected) in [
        ("h1", "# 中😀e\u{301}\r\n"),
        ("p", "段落 **粗**\r\n"),
        ("blockquote", "> 引用\r\n> - 项\r\n"),
        ("blockquote li", "- 项\r\n"),
        // The blank line terminating this list belongs to its source range.
        ("ol", "7. 七\r\n8. 八\r\n\r\n"),
        ("pre", "```rust\r\n<x>&\r\n```"),
        ("hr", "---\r\n"),
    ] {
        assert_eq!(source(select(&doc, selector), md), expected, "{selector}");
    }
    assert_eq!(select(&doc, "ol").value().attr("start"), Some("7"));
    assert_eq!(select(&doc, "code").text().collect::<String>(), "<x>&\n");
    assert_eq!(
        select(&doc, "code").value().attr("class"),
        Some("language-rust")
    );
    assert!(select(&doc, "code")
        .value()
        .attr("data-src-start")
        .is_none());
    assert_eq!(select(&doc, "strong").text().collect::<String>(), "粗");
}

#[test]
fn tables_and_footnotes_have_direct_ranges_and_preserve_semantics() {
    let md =
        "| 左 | 右 |\n| :-- | --: |\n| 甲 | 乙 |\n\n见[^b]和[^a]。\n\n[^a]: 第一\n\n[^b]: 第二\n";
    let doc = Html::parse_fragment(&render_html(md.into()));
    assert_eq!(
        source(select(&doc, "table"), md),
        "| 左 | 右 |\n| :-- | --: |\n| 甲 | 乙 |\n"
    );
    assert_eq!(source(select(&doc, "td"), md).trim(), "甲");
    assert_eq!(
        select(&doc, "th").value().attr("style"),
        Some("text-align: left")
    );
    assert_eq!(
        select(&doc, "td:nth-child(2)").value().attr("style"),
        Some("text-align: right")
    );
    for block in doc.select(&Selector::parse("table, thead, tbody, tr, th, td, div, p").unwrap()) {
        source(block, md); // all offsets must be valid UTF-8 boundaries
    }
    for name in ["a", "b"] {
        let label = select(&doc, &format!("[id='{name}'] .footnote-definition-label"));
        let link = select(&doc, &format!("a[href='#{name}']"));
        assert_eq!(
            label.text().collect::<String>(),
            link.text().collect::<String>()
        );
        assert!(
            source(select(&doc, &format!("[id='{name}']")), md).starts_with(&format!("[^{name}]:"))
        );
    }
}

#[test]
fn untrusted_html_and_obfuscated_urls_are_inert_but_safe_urls_survive() {
    let md = concat!(
        "<script>alert(1)</script>\n\n",
        "inline <img src=x onerror=alert(2)>\n\n",
        "[a](javascript:alert%281%29) [b](JaVaScRiPt:x) ",
        "[c](java&#x09;script:x) [d](vbscript:x) [e](data:text/html,boom) ",
        "![svg](data:image/svg+xml;base64,PHN2Zz4=) ",
        "![html](data:text/html;base64,QQ==) ",
        "[web](https://example.com/a?q=1&b=2) [local](./a.md) [hash](#a) ",
        "[mail](mailto:a@example.com) ![raster](data:image/png;base64,AA==)\n"
    );
    let doc = Html::parse_fragment(&render_html(md.into()));
    assert!(doc
        .select(&Selector::parse("script, [onerror]").unwrap())
        .next()
        .is_none());
    assert!(doc
        .root_element()
        .text()
        .collect::<String>()
        .contains("<script>alert(1)</script>"));
    for label in ["a", "b", "c", "d", "e"] {
        let link = doc
            .select(&Selector::parse("a").unwrap())
            .find(|node| node.text().collect::<String>() == label)
            .unwrap();
        assert_eq!(link.value().attr("href"), Some("#"), "{label}");
    }
    for alt in ["svg", "html"] {
        assert_eq!(
            select(&doc, &format!("img[alt='{alt}']"))
                .value()
                .attr("src"),
            Some("#")
        );
    }
    for href in [
        "https://example.com/a?q=1&b=2",
        "./a.md",
        "#a",
        "mailto:a@example.com",
    ] {
        assert!(doc
            .select(&Selector::parse("a").unwrap())
            .any(|a| a.value().attr("href") == Some(href)));
    }
    assert_eq!(
        select(&doc, "img[alt='raster']").value().attr("src"),
        Some("data:image/png;base64,AA==")
    );
}

#[test]
fn empty_input_and_inline_features_render_without_a_page_wrapper() {
    assert_eq!(render_html(String::new()), "");
    let output = render_html("- [x] ~~done~~ and `code`\n\n![**alt**](image.png)\n".into());
    assert!(!output.contains("<html") && !output.contains("<body"));
    let doc = Html::parse_fragment(&output);
    assert!(select(&doc, "input").value().attr("disabled").is_some());
    assert!(select(&doc, "input").value().attr("checked").is_some());
    assert_eq!(select(&doc, "del").text().collect::<String>(), "done");
    assert_eq!(select(&doc, "img").value().attr("alt"), Some("alt"));
}
