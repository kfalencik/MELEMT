# MELEMT

**Mass Effect Legendary Edition Mod Tool**: a native macOS mod manager for Mass Effect Legendary Edition running through Steam (with NotProton) or CrossOver.

- Installs ME3Tweaks Mod Manager–format mods (`moddesc.ini`): Custom DLC, `[BASEGAME]` files, merge mods, TLK/2DA/Coalesced/PlotManager merges and AutoTOC. It uses the same ME3TweaksCore and LegendaryExplorerCore libraries as ME3Tweaks Mod Manager.
- Opens **Mod Manager Download** links from Nexus Mods, and picks up archives (`.7z`, `.zip`, `.rar`) you drop on the window or save to Downloads.
- Sets each game up to load mods (bink bypass and ASI loader), and backs up every original file before changing it.
- Starts any of the three games straight from its launcher screen.
- Updates itself with [Sparkle](https://sparkle-project.org).

## Download

Get **MELEMT-x.y.zip** from the [latest release](https://github.com/kfalencik/MELEMT/releases/latest), unzip it and move **MELEMT.app** to Applications. It's signed and notarized, and checks for updates on its own (you can also use **MELEMT ▸ Check for Updates…**).

Requires macOS 27 or later and Mass Effect Legendary Edition from Steam, running through NotProton or Steam in a CrossOver bottle.

## Building from source

Requirements: Xcode 27, the [.NET 10 SDK](https://dot.net) in `~/.dotnet`, and [Rust](https://rustup.rs) in `~/.cargo`.

```sh
git clone https://github.com/kfalencik/MELEMT.git
cd MELEMT
Helper/fetch-sources.sh   # ME3TweaksCore + LegendaryExplorerCore + oozextract, with the macOS patches
Helper/build-helper.sh    # builds MEMT/Helper/LEModHelper
open MEMT.xcodeproj
```

`LEModHelper` is the command-line tool the app runs for the steps that edit game packages. Its source is in `Helper/LEModHelper`, and the small macOS fixes to the upstream libraries are in `Helper/patches`.

## Releasing

One-time setup:

1. A **Developer ID Application** certificate in your login keychain.
2. Notarization credentials: `xcrun notarytool store-credentials MELEMT --apple-id <you> --team-id 37KPZYVX63`
3. The Sparkle signing key in your login keychain (account `MELEMT`). Keep a backup with
   `generate_keys --account MELEMT -x melemt-sparkle-key.txt`. Without it you can't ship updates to existing users.
4. `gh auth login`

Then commit your changes and run:

```sh
scripts/release.sh 1.1 notes.md
```

The script builds a Release build, signs it (Sparkle, the helper and the app), notarizes and staples it, zips it, creates the GitHub release, and adds the update to `appcast.xml`, which installed copies read to find updates.

## Credits

- [ME3TweaksCore](https://github.com/ME3Tweaks/ME3TweaksCore) and [LegendaryExplorerCore](https://github.com/ME3Tweaks/LegendaryExplorer) by ME3Tweaks (GPL-3.0). The bink bypass, AutoTOC and LE1 Autoload Enabler files in `MEMT/GameSetup` also come from ME3Tweaks.
- [oozextract](https://github.com/lvlvllvlvllvlvl/oozextract) (MIT) for Oodle decompression.
- [Sparkle](https://sparkle-project.org) (MIT) for updates.
- Microsoft Visual C++ runtime DLLs, redistributed for the game's ASI mods.

MELEMT isn't affiliated with BioWare, Electronic Arts or ME3Tweaks. Mass Effect is a trademark of EA International (Studio and Publishing) Ltd.

## License

GPL-3.0. See [LICENSE](LICENSE).
