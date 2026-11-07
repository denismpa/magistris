# Magistris iPadOS build and validation

Run the commands from the root of the checked-out `feature/percussion-editing` worktree. Record the commit with `git rev-parse HEAD`.

## Prerequisites

- Use full Xcode with the iOS 27.1 SDK or later. Aria’s iPhone Duo code references UIKit APIs first declared in that SDK. The app’s deployment target is iPadOS 17. Xcode 27.1 requires macOS Tahoe 26.6 or later. [Apple’s Xcode requirements](https://developer.apple.com/xcode/system-requirements/) and [UIKit SDK notes](https://developer.apple.com/documentation/updates/uikit).
- Install CMake 3.26 or newer, Ninja, Git LFS, and matching Qt 6.11.0 SDKs for macOS and iOS. For Apple silicon Simulator builds, use the arm64 Simulator Qt produced by `MuseReaderiOS/scripts/build-qt-ios-simulator.sh` and install a compatible iPad simulator runtime in Xcode.
- Fetch the Git LFS SoundFont with `git lfs pull`. Confirm `MuseReaderiOS/MuseReaderiOS/Resources/MuseScore_General.sf2` is the binary, with a `RIFF` header. The app uses it for playback.
- Set `ARIA_QT_HOST`, `ARIA_QT_DEVICE`, and, for simulator builds, `ARIA_QT_SIMULATOR` to the Qt SDK roots. Each root should contain `lib/cmake/Qt6/Qt6Config.cmake`. Set `ARIA_OUT` to an absolute local output directory and run `mkdir -p "$ARIA_OUT"`. Keep the existing render-core outputs under `/tmp` available for incremental builds.

```sh
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
cmake --version
ninja --version
file MuseReaderiOS/MuseReaderiOS/Resources/MuseScore_General.sf2
```

## Simulator and native regression checks

Use Release on the simulator as specified in `ONBOARDING.md`. Use `xcrun simctl list devices available` to find an iPad simulator ID and set `ARIA_IPAD_SIM` to it.

```sh
xcodebuild test -project MuseReaderiOS/Aria.xcodeproj -scheme Aria \
  -configuration Release -destination "id=$ARIA_IPAD_SIM" \
  -derivedDataPath "$ARIA_OUT/DerivedData-Simulator" \
  -resultBundlePath "$ARIA_OUT/Aria-Simulator.xcresult" \
  -parallel-testing-enabled NO ARCHS=arm64 CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  MUSEREADER_QT_HOST_SDK_DIR="$ARIA_QT_HOST" \
  MUSEREADER_QT_IOS_SDK_DIR="$ARIA_QT_DEVICE" \
  MUSEREADER_QT_IOS_SIMULATOR_SDK_DIR="$ARIA_QT_SIMULATOR"
```

With macOS Qt, FreeType, and HarfBuzz installed, build and run the host tests and the MSCZ round-trip suite. Use separate `--out` directories for each report because the compatibility script replaces its output folder on every run. Compare both reports to the baseline in `sandbox/engraving/compat/README.md` using desktop MuseScore Studio 4.7.6.

```sh
cmake -S sandbox/engraving -B build-aria-475-host -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DSCORE_RENDER_BUILD_TESTS=ON \
  -DQt6_DIR="$ARIA_QT_HOST/lib/cmake/Qt6" \
  -DSCORE_RENDER_QT_HOST_ROOT="$ARIA_QT_HOST"
cmake --build build-aria-475-host
ctest --test-dir build-aria-475-host --output-on-failure
python3 sandbox/engraving/compat/roundtrip_475.py --out "$ARIA_OUT/roundtrip"
python3 sandbox/engraving/compat/roundtrip_475.py --direct \
  --out "$ARIA_OUT/roundtrip-direct"
```

## Device install and TestFlight

For personal testing, the owner can sign in to Xcode, choose a Personal Team or paid development team, pair and trust an iPad, enable Developer Mode on it, then select the iPad and run the Aria scheme in Release. Choose a bundle identifier that the team controls. The repository’s default `com.hdi200.ariascore` belongs to the original app. Keep team and bundle overrides local. A Personal Team’s profiles expire after seven days. [Apple’s Personal Team instructions](https://developer.apple.com/help/account/basics/about-your-developer-account) and [Developer Mode guide](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

For a distribution archive, set `ARIA_TEAM_ID` and `ARIA_BUNDLE_ID` to values for the owner’s paid Apple Developer Program team and its registered app identifier. Configure automatic signing for that team in Xcode first.

```sh
xcodebuild archive -project MuseReaderiOS/Aria.xcodeproj -scheme Aria \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARIA_OUT/Magistris.xcarchive" \
  -derivedDataPath "$ARIA_OUT/DerivedData-Device" \
  DEVELOPMENT_TEAM="$ARIA_TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$ARIA_BUNDLE_ID" \
  MUSEREADER_QT_HOST_SDK_DIR="$ARIA_QT_HOST" \
  MUSEREADER_QT_IOS_SDK_DIR="$ARIA_QT_DEVICE"
```

In Xcode Organizer, export an Ad Hoc IPA to install on the devices in its profile. For TestFlight, use App Store Connect distribution with a matching app record, unique build number, and distribution signing. The owner manages credentials and upload. For distribution, follow `MuseReaderiOS/OPEN_SOURCE_COMPLIANCE.md` and retain the source for the exact archived commit. [Apple’s registered-device distribution guide](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices) and [beta distribution guide](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).

## Acceptance on an iPad with Apple Pencil

1. Create a score and import an existing MSCZ. Add a five-line drum kit and a single-line unpitched instrument, such as snare drum. Select a note or rest in the staff, choose an instrument from the percussion menu, and tap **Enter Note**. Check notes, rests, durations, voices and noteheads, including kit sounds sharing a staff position and a score with a custom drum map.
2. Use Pencil to select and insert on both staves and on a pitched staff. Choose **By staff position** to follow the tip vertically or choose an instrument to fix its staff line. Check adjacent staff positions, zoom and rotation, cancellation during a gesture, finger scrolling and zooming, and quick successive entry. Verify that a gesture commits one edit and that undo/redo restores the previous notation.
3. Save, reopen in Magistris, and export MSCZ. Open it in MuseScore Studio 4.7.6, confirm the 4.70 file version and the resulting drum mapping, notation and playback. Verify a linked part if the score has one.

## Build environment observed

The Mac has macOS 26.0.1 and the Command Line Tools. `xcodebuild` cannot run with that toolchain, and no iOS SDK, iPad simulator runtime, valid signing identity, or provisioning profile was detected. Desktop MuseScore Studio 4.7.6 is installed. The branch workflow `aria-ipados-validation.yml` builds an unsigned iPad-capable archive using the GitHub Actions `xcode-27` arm64 runner. The archive verifies the device build. Installation and TestFlight require signing, and the Apple Pencil checks require a physical iPad. [GitHub runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).
