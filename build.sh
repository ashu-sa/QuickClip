#!/usr/bin/env bash
set -e

echo "🔨 Building QuickClip..."
swiftc -O QuickClip.swift -o QuickClip -framework Cocoa -framework SwiftUI -framework Carbon

echo "📦 Updating App Bundle..."
mkdir -p "QuickClip.app/Contents/MacOS" "QuickClip.app/Contents/Resources"
cp QuickClip "QuickClip.app/Contents/MacOS/QuickClip"

echo "🔐 Ad-hoc Codesigning..."
codesign --force --deep --sign - "QuickClip.app"

echo "✅ Build complete! You can open it with: open QuickClip.app"
