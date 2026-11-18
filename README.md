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

## Build (macOS viewer prototype)

```sh
apps/macos/build.sh
open "apps/macos/build/Lots Markdown.app" --args /path/to/file.md
```

Requires Xcode and Rust. `apps/render-stub/` is a temporary renderer until `core/` ships its FFI.

## License

Apache-2.0. See [LICENSE](LICENSE).
