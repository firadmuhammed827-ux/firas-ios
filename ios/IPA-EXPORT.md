# Exporting Firas AI as an IPA

The project is configured for automatic signing. On a Mac with Xcode 26 or
newer, open `FirasAI.xcodeproj`, choose the Firas AI target, and select the
owner's Apple Developer Team under **Signing & Capabilities** once.

After that, either use **Product → Archive → Distribute App** in Xcode, or run:

```bash
cd ios
chmod +x export-ipa.sh
./export-ipa.sh
```

The exported package is written to `ios/build/export/`. A physical `.ipa`
cannot be signed on Windows: Apple requires Xcode, a Developer Team, and the
matching distribution profile on macOS.
