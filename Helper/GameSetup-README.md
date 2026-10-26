# Game setup files

Files in MEMT/GameSetup, installed automatically into `Game/MEx/Binaries/Win64` so Legendary Edition can load mods, the same
files ME3Tweaks Mod Manager installs:

| File here | Installed as | Source |
|---|---|---|
| bink2w64-bypass.dll | bink2w64.dll | ME3TweaksCore `GameFilesystem/Bink/64/bink2w64.dll` (signature bypass + ASI loader) |
| bink2w64-original.dll | bink2w64_original.dll | ME3TweaksCore `GameFilesystem/Bink/64/bink2w64_enhanced.dll` |
| AutoTOCLE-v2.asi | ASI/AutoTOCLE-v2.asi | ME3Tweaks ASI manifest (all LE games) |
| LE1AutoloadEnabler-v12.asi | ASI/LE1AutoloadEnabler-v12.asi | ME3Tweaks ASI manifest (Mass Effect only) |

To update the ASIs, run `LEModHelper prepare-game` and copy the new files from
`~/Library/Application Support/ME3Tweaks/CachedASIs`.
