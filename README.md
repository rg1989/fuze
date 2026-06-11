# Fuse

One menu-bar app replacing six utilities on Apple Silicon Macs (macOS 14+):
push-to-talk local Whisper dictation, window tiling, clipboard history with
paste picker, smart video downloading (yt-dlp), per-device scroll reversal,
and one-keystroke notification clearing.

## Build

    brew bundle              # installs xcodegen
    xcodegen generate
    xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build
    open .build/Build/Products/Debug/Fuse.app

## Test

    xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test

Plans: `docs/superpowers/plans/2026-06-11-fuse/`
