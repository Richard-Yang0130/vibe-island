# Vibeisland Branding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package and install the existing app as `Vibeisland.app` with a generated sunny tropical-island icon while retaining all CodexBar identifiers and settings.

**Architecture:** Keep the executable, bundle identifier, app group, helpers, and runtime behavior unchanged. Rename only the outer app bundle and display metadata, and feed a new raster master through the repository's existing `.icon` and `.icns` pipeline.

**Tech Stack:** Bash packaging scripts, macOS `iconutil`/`codesign`/`plutil`, Codex built-in image generation, Swift app bundle.

---

### Task 1: Generate and install the icon source

**Files:**
- Create: `output/imagegen/vibeisland-icon.png`
- Modify: `Icon.icon/Assets/codexbar.png`
- Modify: `Sources/CodexBar/Resources/Icon-classic.icns`

- [x] **Step 1: Generate the final square icon with Codex's built-in image generation tool**

Use case: `logo-brand`. Generate a square, bright, joyful tropical-island app icon with turquoise ocean, a small golden sandy beach, one elegant palm tree, and a warm rising sun. Use a polished dimensional illustration style for a premium macOS app icon, clean shapes, vivid natural colors, a centered silhouette, and strong small-size legibility. Include no text, letters, people, logos, watermark, border, or device mockup. Copy the generated final into `output/imagegen/vibeisland-icon.png`.

Expected: a square PNG at `output/imagegen/vibeisland-icon.png`.

- [x] **Step 2: Replace the icon master and rebuild the classic icon**

```bash
cp output/imagegen/vibeisland-icon.png Icon.icon/Assets/codexbar.png
./Scripts/build_icon.sh Icon.icon Icon build/icon
cp Icon.icns Sources/CodexBar/Resources/Icon-classic.icns
```

Expected: `Icon.icns` and `Sources/CodexBar/Resources/Icon-classic.icns` are valid ICNS files derived from the new image.

- [x] **Step 3: Verify icon files**

```bash
sips -g pixelWidth -g pixelHeight Icon.icon/Assets/codexbar.png
iconutil --convert iconset --output /tmp/vibeisland-icon-check.iconset Sources/CodexBar/Resources/Icon-classic.icns
```

Expected: the PNG is square and `iconutil` exits successfully.

### Task 2: Rename the packaged app shell

**Files:**
- Modify: `scripts/test_package_info_plist.sh`
- Modify: `Scripts/package_app.sh`
- Modify: `Scripts/compile_and_run.sh`
- Modify: `Scripts/launch.sh`

- [x] **Step 1: Add failing display-name assertions**

Add `APP_NAME=Vibeisland` beside the other test variables in `scripts/test_package_info_plist.sh`, then add:

```python
assert plist["CFBundleName"] == "Vibeisland"
assert plist["CFBundleDisplayName"] == "Vibeisland"
assert plist["CFBundleExecutable"] == "CodexBar"
```

- [x] **Step 2: Run the focused test and verify it fails**

```bash
./scripts/test_package_info_plist.sh
```

Expected: FAIL because the generated plist still names the app `CodexBar`.

- [x] **Step 3: Apply the minimal package rename**

In `Scripts/package_app.sh`, define `APP_NAME="Vibeisland"`, use it for `APP_FINAL`, `APP_STAGE`, `CFBundleName`, and `CFBundleDisplayName`, while leaving `CFBundleExecutable` as `CodexBar`.

Update `APP_BUNDLE` and the bundle portion of `APP_PROCESS_PATTERN` in `Scripts/compile_and_run.sh`; update `APP_PATH`, process matching, and user-facing errors in `Scripts/launch.sh` to point to `Vibeisland.app` while still checking the `CodexBar` executable process.

- [x] **Step 4: Run the focused test and shell validation**

```bash
./scripts/test_package_info_plist.sh
bash -n Scripts/package_app.sh Scripts/compile_and_run.sh Scripts/launch.sh
git diff --check
```

Expected: the plist test passes; both shell checks and `git diff --check` exit 0.

### Task 3: Build, install, and launch

**Files:**
- Build output: `Vibeisland.app`
- Install output: `/Applications/Vibeisland.app`

- [x] **Step 1: Build and launch the packaged app**

```bash
./Scripts/compile_and_run.sh
```

Expected: `Vibeisland.app` is created, signed, launched, and remains running.

- [x] **Step 2: Verify name, compatibility identifiers, icon, and signature**

```bash
test "$(plutil -extract CFBundleDisplayName raw Vibeisland.app/Contents/Info.plist)" = Vibeisland
test "$(plutil -extract CFBundleExecutable raw Vibeisland.app/Contents/Info.plist)" = CodexBar
test "$(plutil -extract CFBundleIdentifier raw Vibeisland.app/Contents/Info.plist)" = com.steipete.codexbar
codesign --verify --deep --strict Vibeisland.app
test -f Vibeisland.app/Contents/Resources/Icon.icns
```

Expected: every command exits 0.

- [x] **Step 3: Replace the mistaken installation and open Vibeisland**

```bash
ditto Vibeisland.app /Applications/.Vibeisland.installing.app
codesign --verify --deep --strict /Applications/.Vibeisland.installing.app
rm -rf /Applications/Vibeisland.app
mv /Applications/.Vibeisland.installing.app /Applications/Vibeisland.app
open /Applications/Vibeisland.app
```

Expected: `/Applications/Vibeisland.app` launches and its menu-bar UI appears. Remove `/Applications/CodexBar.app` only after verifying Vibeisland launches, because that path contains the mistaken copy installed in this session.

- [x] **Step 4: Commit only branding changes**

```bash
git add Scripts/package_app.sh Scripts/compile_and_run.sh Scripts/launch.sh scripts/test_package_info_plist.sh Icon.icon/Assets/codexbar.png Sources/CodexBar/Resources/Icon-classic.icns output/imagegen/vibeisland-icon.png
git commit -m "Brand app as Vibeisland"
```
