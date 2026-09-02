# Vibeisland App Branding Design

## Goal

Package the existing app as `Vibeisland.app` with a new sunny beach icon while preserving all current behavior, settings, and task integrations.

## Scope

- Change the packaged app filename to `Vibeisland.app`.
- Set `CFBundleName` and `CFBundleDisplayName` to `Vibeisland`.
- Generate a text-free macOS app icon with a bright tropical island, golden beach, blue water, palm tree, and warm sun.
- Keep the existing executable name, bundle identifier, app-group identifier, preferences, helper names, and widget internals unchanged for compatibility.

## Implementation

Use the existing packaging and icon pipelines. Replace the source icon asset, rebuild `Icon-classic.icns`, and make the package script emit `Vibeisland.app`. Do not rename Swift targets or product identifiers.

## Verification

- Build the packaged app.
- Confirm the output is `Vibeisland.app` and its display/name metadata is `Vibeisland`.
- Verify the bundle signature.
- Launch the packaged app and confirm the process remains running.
- Confirm the installed app uses the generated icon.
