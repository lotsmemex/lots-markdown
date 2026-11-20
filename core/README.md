# Lots Markdown Core v0

共享渲染库，当前唯一公开接口：

```rust
pub fn render_html(markdown: String) -> String
```

返回 HTML 片段，不含页面、CSS 或脚本。支持 CommonMark、表格、脚注、删除线和任务列表。

## 源码定位

- 块元素携带 `data-src-start` / `data-src-end`，是原输入的 UTF-8 全文字节半开区间，不是 Swift/Kotlin 的字符索引或 UTF-16 索引。
- 直接采用解析器的块范围，包含 Markdown 语法。块尾空白是否属于范围取决于块类型；代码围栏的结束换行不包含在范围内。输入不做换行或 Unicode 规范化。
- 嵌套块各自有范围；代码块标在 `<pre>`，不标在内部 `<code>`。表格直接标在 `<table>`、行、单元格上，不额外包 `<div>`；解析器没有独立事件的 `<tbody>` 使用整个表格的范围。
- 脚注定义直接标在 `.footnote-definition` 的 `<div>` 上，编号与引用一致。行内元素无需范围。

## 安全边界

原生 HTML 显示成文本。绝对 URL 仅允许 HTTP/HTTPS、链接中的 mailto，以及图片中的 base64 PNG/JPEG/GIF/WebP/AVIF/BMP/ICO；其他 scheme（包括 SVG data URL）替换为 `#`。相对路径和片段保留。检查 scheme 时考虑浏览器忽略的 ASCII 控制字符，HTML 属性由渲染器转义。

这是同步 CPU 操作，三端应在后台线程调用。外壳仍须关闭预览 JavaScript，并限制导航、文件访问与远程资源策略；库不负责 WebView 策略、文件读取、CSS 或网络请求。偏移不等于完整的预览文本选区映射，后者不在 v0 范围。

## 构建与生成绑定

以下命令从 `core/` 目录执行。`Cargo.lock` 固定依赖；不需要单独安装 UniFFI CLI。生成物在忽略的 `target/`，不要手改或提交。

```sh
cargo test --locked
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo build --locked --features bindings
cargo run --locked --features bindings --bin uniffi-bindgen -- generate \
  target/debug/liblots_markdown_core.dylib --language swift --out-dir target/bindings/swift
cargo run --locked --features bindings --bin uniffi-bindgen -- generate \
  target/debug/liblots_markdown_core.dylib --language kotlin --out-dir target/bindings/kotlin --no-format
```

`uniffi.toml` 自动从 crate 目录读取。Swift 生成 `LotsMarkdownCore.swift`、`LotsMarkdownCoreFFI.h` 和 `.modulemap`，调用 `renderHtml(markdown:)`。将生成的 Swift 源码和 FFI 模块加入原生构建，并链接对应平台的 Rust 库。iOS 需分别构建 `aarch64-apple-ios` 和 `aarch64-apple-ios-sim`，不能链接 macOS 动态库。

Kotlin 生成包 `com.lotsmemex.markdown.core`，调用 `renderHtml(markdown)`。Android 构建需配置 NDK linker，分别生成所需 ABI 的 `liblots_markdown_core.so` 并放入对应 `jniLibs/<abi>/`。生成的 Kotlin 绑定通过 **JNA** 调用 C ABI，不再使用临时桩的手写 JNI；应用需添加兼容的 JNA Android AAR（依赖坐标 `net.java.dev.jna:jna:<兼容版本>@aar`）并保留 JNA 所需的发布混淆规则。绑定与原生库必须来自同一版本。

三端应用接入由前端 owner 负责；此 crate 不修改 `apps/`。
