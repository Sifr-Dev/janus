# Janus

Janus is a native terminal built with Cipher. It opens PTY-backed panes directly in the application process; no multiplexer daemon or companion engine is required.

**Status: 0.1.0 development preview.** Janus is a real application with its own repository, build, tests, and release lifecycle. It is not Nebula. Nebula is the separate multiplexer product; Rex is an external competitor, not part of Janus.

## Requirements

- Zig 0.17.1 to build.
- A Cipher checkout at `../Cipher`, or pass `-Dcipher-root=/path/to/Cipher`.
- A Wayland compositor and system C loader to run. Vulkan is optional when using the software renderer.
- No separately installed Cipher runtime or default font is required; the default font and its OFL license are compiled into the executable.

## Build and test

```sh
zig build -Dcipher-root=/path/to/Cipher
zig build test -Dcipher-root=/path/to/Cipher
zig build dist -Dcipher-root=/path/to/Cipher -Doptimize=ReleaseSafe
```

`zig build dist` installs the actual compiled executable at `zig-out/bin/janus`.
The resulting binary is a standalone application, not a launcher for a separate
Cipher runtime. On the tested Linux x86_64 host, `ldd` reports only the system C
loader and libc; Wayland access and a supported GPU or software renderer remain
runtime platform requirements. The embedded default font and its OFL license are
compiled into the executable.

The tests exercise a real PTY, pane lifecycle, and focus behavior without a display or multiplexer engine.

## Run

```sh
zig-out/bin/janus [--shell /path/to/shell]
```

A bounded smoke run can use `CIPHER_MAX_FRAMES=120 CIPHER_FORCE_SOFTWARE=1` on an existing Wayland session. The actual terminal opens a window; there is no headless screenshot or interactive-workflow claim in the basic unit tests.

## Current behavior

- One PTY, VT parser, and grid per pane.
- Pane creation, focus cycling, and closing.
- Keyboard input, scrollback, clipboard, and file-drop paths in the application code.
- Embedded default font, no engine process, no framework-managed runtime.

## Remaining work

- More interactive and rendering-level regression coverage.
- Font and terminal-width behavior across compositors and displays.
- Distribution packages and release artifacts after compatibility verification.
- Documented configuration and accessibility behavior. Do not claim screen-reader support from the presence of keyboard shortcuts.
