# Lots Markdown

Open-source, free, fast Markdown reader and editor for macOS, iOS and Android, companion to Lots MemeX.

Status: early prototype. Stage 1 is opening and reading Markdown on all three platforms (replacing Typora as a viewer); stage 2 adds editing and custom CSS rendering.

## Layout

| Path | What | Owner |
| --- | --- | --- |
| `core/` | Rust core: Markdown → HTML with source offsets, file formats, search; UniFFI bindings for Swift and Kotlin | back end |
| `apps/macos/` | AppKit app | front end |
| `apps/ios/` | UIKit app | front end |
| `apps/android/` | Kotlin app | front end |
| `themes/` | Rendering CSS and annotation styles | front end |
| `bench/` | Performance benchmarks | front end |
| `docs/` | Specifications and design notes | both |

## macOS app (stage 1)

- Open a Markdown file or a folder (`⌘O`, Finder, or the command line). Folders show a file tree (`⌘0`); right-click a file to reveal it in Finder or copy its full path.
- Edit the source on the left and save with `⌘S`; the bytes on disk are exactly the text you see. Changes made by other apps reload automatically.
- The rendered preview on the right follows edits and scrolling (`⌘\` to hide it). Files over 16 MB preview their first 2 MB.
- Themes (显示 → 主题): 默认, 书卷 and 公众号 are built in. “复制当前主题并编辑…” copies the current theme into `~/Library/Application Support/Lots Markdown/Themes/`; any CSS file there becomes a theme and the preview updates as soon as you save it. A `/* name: … */` first line sets the menu name.
- Closing the last window keeps the app running, so the next file opens without a process launch.

Measurements: [docs/bench](docs/bench/).

## Build (macOS)

```sh
apps/macos/build.sh
open "apps/macos/build/Lots Markdown.app" --args /path/to/file.md
apps/macos/package-dmg.sh   # build/LotsMarkdown-<version>.dmg, ad-hoc signed, not notarized
```

Requires Xcode and Rust. macOS renders through `core/` (UniFFI); iOS and Android still use the temporary `apps/render-stub/`.

## License

Apache-2.0. See [LICENSE](LICENSE).
