using System.Runtime.InteropServices;
using System.Text.Json;
using LegendaryExplorerCore;
using LegendaryExplorerCore.Compression;
using LegendaryExplorerCore.GameFilesystem;
using LegendaryExplorerCore.Unreal;
using ME3TweaksCore;
using ME3TweaksCore.ME3Tweaks.M3Merge;
using ME3TweaksCore.ME3Tweaks.M3Merge.Bio2DATable;
using ME3TweaksCore.ME3Tweaks.M3Merge.GlobalShader;
using ME3TweaksCore.ME3Tweaks.M3Merge.LE1Config;
using ME3TweaksCore.ME3Tweaks.M3Merge.PlotManager;
using ME3TweaksCore.ME3Tweaks.M3Merge.Game2Email;
using ME3TweaksCore.Config;
using ME3TweaksCore.GameFilesystem;
using ME3TweaksCore.TextureOverride;
using LegendaryExplorerCore.Coalesced;
using LegendaryExplorerCore.Coalesced.Config;
using LegendaryExplorerCore.Misc;
using ME3TweaksModManager.modmanager.objects;
using ME3TweaksModManager.modmanager.objects.mod;
using ME3TweaksModManager.modmanager.objects.mod.merge;
using ME3TweaksModManager.modmanager.objects.tlk;

namespace LEModHelper;

/// <summary>
/// Runs the ME3Tweaks Mod Manager install steps that edit game packages, for the Mac app.
///
/// Usage:
///   LEModHelper merges      --game LE1 --gamedir &lt;Game/ME1&gt; --backupdir &lt;dir&gt; --mod &lt;mod root&gt; --cmmver 9.0 [--mergemods a.m3m;b.m3m] [--tlkmerge true] [--tlkoptions k1;k2]
///   LEModHelper config-read --game LE1 --gamedir &lt;Game/ME1&gt; --entries "BIOInput.ini|Engine.PlayerInput|bEnableMouseSmoothing;..."
///   LEModHelper apply-settings --game LE1 --gamedir &lt;Game/ME1&gt; --backupdir &lt;dir&gt; --statedir &lt;dir&gt; [--delta &lt;file.m3cd&gt;]
///   LEModHelper dlc-merge   --game LE2 --gamedir &lt;Game/ME2&gt; --dlcfolder DLC_MOD_X --cmmver 9.2   (per-DLC config delta + texture override merges, at install time)
///   LEModHelper post-install --game LE1 --gamedir &lt;Game/ME1&gt; --backupdir &lt;dir&gt;
///   LEModHelper prepare-game --game LE1 --gamedir &lt;Game/ME1&gt;   (bink bypass + required ASIs)
///   LEModHelper install-asi --game LE1 --gamedir &lt;Game/ME1&gt; --asimods 87:0;12:3   (group:version, 0 = latest)
///
/// Progress lines go to stderr as "PROGRESS: text". The last stdout line is a JSON result:
///   {"ok":true,"backedUp":[...],"messages":[...]} or {"ok":false,"error":"..."}
/// </summary>
internal static class Program
{
    private static readonly List<string> Messages = new();

    /// The real stdout, reserved for the JSON result. Library code that prints to Console.Out is sent
    /// to stderr instead, so the app always finds the result line.
    private static TextWriter ResultOut = Console.Out;

    private static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            return Fail("No command given. Commands: merges, config-read, apply-settings, dlc-merge, post-install, prepare-game, install-asi.");
        }
        // M3 runs with the invariant culture (App.xaml.cs); its parsing and casing depend on it.
        System.Globalization.CultureInfo.DefaultThreadCurrentCulture = System.Globalization.CultureInfo.InvariantCulture;
        System.Globalization.CultureInfo.DefaultThreadCurrentUICulture = System.Globalization.CultureInfo.InvariantCulture;
        System.Globalization.CultureInfo.CurrentCulture = System.Globalization.CultureInfo.InvariantCulture;
        System.Globalization.CultureInfo.CurrentUICulture = System.Globalization.CultureInfo.InvariantCulture;
        ResultOut = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true };
        Console.SetOut(Console.Error);
        var options = ParseOptions(args.Skip(1));
        ME3TweaksModManager.modmanager.diagnostics.M3Log.Verbose = options.ContainsKey("verbose");

        try
        {
            if (!Enum.TryParse<MEGame>(Required(options, "game"), ignoreCase: true, out var game) || !game.IsLEGame())
            {
                return Fail($"Unsupported game '{options["game"]}'. Use LE1, LE2 or LE3.");
            }

            Initialize();

            switch (args[0])
            {
                case "merges":
                {
                    var target = CreateTarget(game, Required(options, "gamedir"));
                    using var backups = new BackupRecorder(target.TargetPath, Required(options, "backupdir"));
                    var mod = CreateMod(game, options);
                    ApplyMergeMods(mod, target, options.GetValueOrDefault("mergemods"));
                    if (string.Equals(options.GetValueOrDefault("tlkmerge"), "true", StringComparison.OrdinalIgnoreCase))
                    {
                        ApplyTLKMerge(mod, target, options.GetValueOrDefault("tlkoptions"));
                    }
                    return Succeed(backups.BackedUp);
                }

                case "config-read":
                {
                    // Current values from the game's base config (the INT file for LE1/LE2).
                    var target = CreateTarget(game, Required(options, "gamedir"));
                    var file = ConfigFiles(target).FirstOrDefault(x => Path.GetFileName(x).Contains("INT", StringComparison.OrdinalIgnoreCase)) ?? ConfigFiles(target).FirstOrDefault()
                        ?? throw new FileNotFoundException("The game's config file (Coalesced) is missing.");
                    using var stream = File.OpenRead(file);
                    var bundle = ConfigAssetBundle.FromSingleStream(game, stream, Path.GetFileName(file));
                    var values = new Dictionary<string, string[]>();
                    foreach (var entry in Required(options, "entries").Split(';', StringSplitOptions.RemoveEmptyEntries))
                    {
                        var parts = entry.Split('|');
                        if (parts.Length != 3) continue;
                        var asset = bundle.GetAsset(parts[0], createIfNotFound: false);
                        if (asset != null && asset.Sections.TryGetValue(parts[1], out var section) && section.TryGetValue(parts[2], out var property))
                        {
                            values[entry] = property.Select(v => v.Value).ToArray();
                        }
                    }
                    ResultOut.WriteLine(JsonSerializer.Serialize(new { ok = true, values, messages = Messages }));
                    return 0;
                }

                case "apply-settings":
                {
                    var target = CreateTarget(game, Required(options, "gamedir"));
                    using var backups = new BackupRecorder(target.TargetPath, Required(options, "backupdir"));
                    ApplySettings(target, game, Required(options, "statedir"), options.GetValueOrDefault("delta"), backups);
                    return Succeed(backups.BackedUp);
                }

                case "dlc-merge":
                {
                    // ModInstaller.cs (Stage: M3CD for LE2, LE3; then texture overrides for cmmver 9.2+).
                    var target = CreateTarget(game, Required(options, "gamedir"));
                    var dlcFolder = Required(options, "dlcfolder");
                    if (dlcFolder.Contains('/') || dlcFolder.Contains('\\') || dlcFolder.Contains(".."))
                    {
                        throw new ArgumentException($"Invalid DLC folder name '{dlcFolder}'.");
                    }
                    var cmmver = double.TryParse(options.GetValueOrDefault("cmmver"), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var cv) ? cv : 9.0;
                    if (game.IsGame2() || game.IsGame3())
                    {
                        Progress($"Merging {dlcFolder} config changes…");
                        M3CConfigMerge.PerformDLCMerge(game, target.GetDLCPath(), dlcFolder);
                    }
                    if (cmmver >= 9.2 && File.Exists(M3CTextureOverrideMerge.GetCombinedTexturePackagePath(target, dlcFolder)) == false)
                    {
                        Progress($"Building {dlcFolder} texture overrides…");
                        var error = M3CTextureOverrideMerge.PerformDLCMerge(target, dlcFolder, deleteTOFiles: true);
                        if (error != null) throw new Exception(error);
                    }
                    ThrowIfSaveFailed();
                    return Succeed(Array.Empty<string>());
                }

                case "prepare-game":
                {
                    // What ME3Tweaks Mod Manager sets up before a game can load mods: the bink bypass
                    // (bundled in ME3TweaksCore) and the AutoTOC / LE1 AutoloadEnabler ASIs (from the
                    // ME3Tweaks ASI manifest).
                    var target = CreateTarget(game, Required(options, "gamedir"));
                    if (!target.IsBinkBypassInstalled())
                    {
                        Progress("Installing the bink bypass…");
                        target.InstallBinkBypass(throwError: true);
                        Messages.Add("Installed the bink bypass");
                    }
                    Progress("Checking ASI mods…");
                    ME3TweaksCore.NativeMods.ASIManager.LoadManifest(overrideThrottling: true);
                    var required = game switch
                    {
                        MEGame.LE1 => new[] { (ME3TweaksCore.NativeMods.ASIModUpdateGroupID.LE1_AutoTOCLE, "AutoTOC"), (ME3TweaksCore.NativeMods.ASIModUpdateGroupID.LE1_AutoloadEnabler, "AutoloadEnabler") },
                        MEGame.LE2 => new[] { (ME3TweaksCore.NativeMods.ASIModUpdateGroupID.LE2_AutoTOCLE, "AutoTOC") },
                        _ => new[] { (ME3TweaksCore.NativeMods.ASIModUpdateGroupID.LE3_AutoTOCLE, "AutoTOC") },
                    };
                    foreach (var (group, name) in required)
                    {
                        Progress($"Installing {name}…");
                        if (!ME3TweaksCore.NativeMods.ASIManager.InstallASIToTargetByGroupID(group, name, target).GetAwaiter().GetResult())
                        {
                            throw new Exception($"Couldn't install the {name} ASI. Check your internet connection and try again.");
                        }
                        Messages.Add($"Installed {name}");
                    }
                    return Succeed(Array.Empty<string>());
                }

                case "install-asi":
                {
                    // [ASIMODS] asimodstoinstall: ASI mods by ME3Tweaks update group, optionally pinned to a version.
                    var target = CreateTarget(game, Required(options, "gamedir"));
                    Progress("Getting the ASI mod list from ME3Tweaks…");
                    ME3TweaksCore.NativeMods.ASIManager.LoadManifest(overrideThrottling: true);
                    foreach (var entry in Required(options, "asimods").Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                    {
                        var parts = entry.Split(':');
                        if (!int.TryParse(parts[0], out var group))
                        {
                            throw new ArgumentException($"Invalid ASI entry '{entry}'.");
                        }
                        var version = parts.Length > 1 && int.TryParse(parts[1], out var v) ? v : 0;
                        var asiMod = ME3TweaksCore.NativeMods.ASIManager.GetASIModsByGame(game)?.FirstOrDefault(x => x.UpdateGroupId == group);
                        var name = asiMod?.LatestVersion?.Name ?? $"ASI mod {group}";
                        Progress($"Installing {name}…");
                        // M3 logs a missing ASI and carries on (ModInstaller.cs) rather than failing the install.
                        if (asiMod == null || !ME3TweaksCore.NativeMods.ASIManager.InstallASIToTargetByGroupID(group, name, target, version).GetAwaiter().GetResult())
                        {
                            Messages.Add($"Warning: couldn't install {name}");
                            continue;
                        }
                        Messages.Add($"Installed {name}");
                    }
                    return Succeed(Array.Empty<string>());
                }

                case "post-install":
                {
                    var target = CreateTarget(game, Required(options, "gamedir"));
                    using var backups = new BackupRecorder(target.TargetPath, Required(options, "backupdir"));
                    RunPostInstallMerges(target, backups);
                    return Succeed(backups.BackedUp);
                }

                default:
                    return Fail($"Unknown command '{args[0]}'.");
            }
        }
        catch (Exception e)
        {
            Console.Error.WriteLine(e);
            return Fail(e.Message);
        }
    }

    // MARK: Setup

    /// <summary>
    /// Points LegendaryExplorerCore's native calls at the bundled macOS libraries (the game's oo2core
    /// DLL and MEM's CompressionWrappers are Windows/Linux-only) and initializes ME3TweaksCore
    /// without its online services.
    /// </summary>
    private static void Initialize()
    {
        NativeLibrary.SetDllImportResolver(typeof(OodleHelper).Assembly, (name, _, _) =>
        {
            if (name.Contains("oo2core", StringComparison.OrdinalIgnoreCase)) return LoadBundledLibrary("liboodle_shim.dylib");
            if (name.Contains("CompressionWrappers", StringComparison.OrdinalIgnoreCase)) return LoadBundledLibrary("libCompressionWrappers.dylib");
            return IntPtr.Zero;
        });
        LoadBundledLibrary("liboodle_shim.dylib");
        // Tell LEC Oodle is available so it doesn't look for the game's Windows oo2core DLL
        // (LoadOodleDll needs a file path, which the single-file bundle doesn't expose).
        typeof(OodleHelper).GetField("dllLoaded", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!
            .SetValue(null, true);

        // No Oodle compressor exists on macOS; uncompressed packages load normally in game.
        PackageSaver.NeverCompress = true;

        string saveError = null;
        ME3TweaksCoreLib.Initialize(new ME3TweaksCoreLibInitPackage
        {
            LoadAuxiliaryServices = false,
            LoadBuildInfo = false,
            RunOnUiThreadDelegate = action => action(),
            LECPackageSaveFailedCallback = message => saveError = message,
        });
        PackageSaveFailed = () => saveError;
    }

    private static Func<string> PackageSaveFailed = () => null;

    /// Loads a native library shipped with the helper: next to the executable in development builds,
    /// or from the single-file bundle's extraction folder in the published build.
    private static IntPtr LoadBundledLibrary(string fileName)
    {
        var besideExecutable = Path.Combine(AppContext.BaseDirectory, fileName);
        if (NativeLibrary.TryLoad(besideExecutable, out var handle)) return handle;
        return NativeLibrary.Load(fileName, typeof(Program).Assembly, DllImportSearchPath.ApplicationDirectory | DllImportSearchPath.AssemblyDirectory);
    }

    /// <summary>LEC reports save failures through a callback instead of throwing; turn them into errors.</summary>
    private static void ThrowIfSaveFailed()
    {
        if (PackageSaveFailed() is { } error)
        {
            throw new Exception(error);
        }
    }

    private static GameTarget CreateTarget(MEGame game, string gameDirectory)
    {
        gameDirectory = gameDirectory.TrimEnd('/', '\\');
        if (!Directory.Exists(Path.Combine(gameDirectory, "BioGame")))
        {
            throw new DirectoryNotFoundException($"{gameDirectory} is not a {game} game folder (no BioGame folder).");
        }
        // On Windows LEC finds the game through the registry; here, point it at the target so code that
        // looks up the game without an explicit path (class imports in compiled scripts) works.
        switch (game)
        {
            case MEGame.LE1: LE1Directory.DefaultGamePath = gameDirectory; break;
            case MEGame.LE2: LE2Directory.DefaultGamePath = gameDirectory; break;
            case MEGame.LE3: LE3Directory.DefaultGamePath = gameDirectory; break;
        }
        // skipInit avoids the Windows-only executable/registry checks; only paths are needed here.
        return new GameTarget(game, gameDirectory, currentRegistryActive: false, isCustomOption: false, isTest: false, skipInit: true);
    }

    private static Mod CreateMod(MEGame game, Dictionary<string, string> options)
    {
        var mod = new Mod
        {
            ModName = options.GetValueOrDefault("modname") ?? "Mod",
            ModPath = Required(options, "mod"),
            Game = game,
            ModDescTargetVersion = double.TryParse(options.GetValueOrDefault("cmmver"), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : 9.0,
        };

        // Legacy (uncompressed) TLK merges are loose xml files in GAME1_EMBEDDED_TLK; newer mods ship a single .m3za.
        // Same rules as M3 (Mod-Parsing.cs): subfolders only from moddesc 9.0, where each subfolder is an option key.
        var tlkFolder = Path.Combine(mod.ModPath, Mod.Game1EmbeddedTlkFolderName);
        if (game == MEGame.LE1 && Directory.Exists(tlkFolder))
        {
            var searchType = mod.ModDescTargetVersion >= 9.0 ? SearchOption.AllDirectories : SearchOption.TopDirectoryOnly;
            var files = MEDirectories.GetFilesOrdered(tlkFolder, "*.xml", searchType)
                .Select(x => Path.GetRelativePath(tlkFolder, x))
                .ToList();
            foreach (var file in files)
            {
                if (Path.GetFileName(file).Count(c => c == '.') < 2)
                {
                    throw new Exception($"TLK merge file {file} must have at least two '.' in its name (package name, export path and extension).");
                }
                var parent = Path.GetDirectoryName(file);
                if (mod.ModDescTargetVersion >= 9.0 && !string.IsNullOrEmpty(parent))
                {
                    mod.LE1TLKMergeAllOptionKeys ??= new List<string>();
                    var optionName = Path.GetFileName(parent);
                    if (!mod.LE1TLKMergeAllOptionKeys.Contains(optionName)) mod.LE1TLKMergeAllOptionKeys.Add(optionName);
                }
            }
            if (files.Any())
            {
                mod.InstallationJobs.Add(new ModJob { Header = ModJob.JobHeader.GAME1_EMBEDDED_TLK, Game1TLKXmls = files });
            }
        }
        return mod;
    }

    // MARK: Install steps

    private static void ApplyMergeMods(Mod mod, GameTarget target, string mergeModList)
    {
        if (string.IsNullOrWhiteSpace(mergeModList)) return;

        var mergeMods = new List<IMergeMod>();
        foreach (var name in mergeModList.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var relative = name.Replace('\\', '/').TrimStart('/');
            if (relative.Contains(".."))
            {
                throw new Exception($"Merge mod name '{name}' contains '..', which is not allowed.");
            }
            var path = Path.Combine(mod.ModPath, Mod.MergeModFolderName, relative);
            if (!File.Exists(path))
            {
                throw new FileNotFoundException($"Merge mod {relative} is missing from the mod's MergeMods folder.");
            }
            // The stream stays open: assets are read lazily while the merge is applied.
            var mm = MergeModLoader.LoadMergeMod(File.OpenRead(path), relative, loadAssets: false)
                ?? throw new Exception($"Couldn't load merge mod {relative}. It may need a newer version of Mod Manager.");
            mergeMods.Add(mm);
        }

        var mmp = new MergeModPackage
        {
            Target = target,
            AssociatedMod = mod,
            OpenedBasegameCache = new PackageCache { CacheMaxSize = 4 },
        };
        foreach (var mm in mergeMods)
        {
            Progress($"Applying merge mod {mm.MergeModFilename}…");
            mm.ApplyMergeMod(mmp, _ => { });
            ThrowIfSaveFailed();
        }
    }

    private static void ApplyTLKMerge(Mod mod, GameTarget target, string optionKeys)
    {
        if (mod.Game != MEGame.LE1) return;
        var hasCompressed = File.Exists(Path.Combine(mod.ModPath, Mod.Game1EmbeddedTlkFolderName, Mod.Game1EmbeddedTlkCompressedFilename));
        if (!hasCompressed && mod.GetJob(ModJob.JobHeader.GAME1_EMBEDDED_TLK) == null) return;
        if (mod.GetJob(ModJob.JobHeader.GAME1_EMBEDDED_TLK) == null)
        {
            mod.InstallationJobs.Add(new ModJob { Header = ModJob.JobHeader.GAME1_EMBEDDED_TLK });
        }

        mod.LE1TLKMergeChosenOptionKeys = optionKeys?.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList() ?? new List<string>();

        Progress("Updating game text (TLK merge)…");
        var mergeFiles = mod.PrepareTLKMerge(out CompressedTLKMergeData compressedData);
        var gameMap = MELoadedFiles.GetFilesLoadedInGame(target.Game, gameRootOverride: target.TargetPath);
        var cache = new PackageCache { CacheMaxSize = 12 };
        int done = 0;
        foreach (var (packageName, xmlFiles) in mergeFiles)
        {
            for (int i = 0; i < xmlFiles.Count; i++)
            {
                var error = mod.InstallTLKMerge(xmlFiles[i], compressedData, gameMap, i == xmlFiles.Count - 1, cache, target, mod, null);
                if (error != null) throw new Exception(error);
                ThrowIfSaveFailed();
            }
            done++;
            Progress($"Updating game text (TLK merge) {done}/{mergeFiles.Count}…");
        }
    }

    /// <summary>
    /// The merges M3 runs after any install (PanelResult.AddTargetMerges / MainWindow-Merging.cs), in
    /// M3's order, followed by AutoTOC so the game sees the new file sizes:
    /// LE1: PlotManager, Coalesced, 2DA, shaders. LE2: PlotManager, merge DLC (squadmate outfits, emails),
    /// shaders. LE3: merge DLC (squadmate outfits), shaders.
    /// Like M3, each step runs on its own, so one failing doesn't leave the rest undone.
    /// </summary>
    private static void RunPostInstallMerges(GameTarget target, BackupRecorder backups)
    {
        var failures = new List<string>();
        void Step(string name, Action action)
        {
            try
            {
                action();
                ThrowIfSaveFailed();
            }
            catch (Exception e)
            {
                Console.Error.WriteLine(e);
                failures.Add($"{name}: {e.Message}");
            }
        }
        var cooked = Path.Combine(target.TargetPath, "BioGame", "CookedPCConsole");

        if (target.Game.SupportsPlotManagerSync())
        {
            Step("Plot manager sync", () =>
            {
                Progress("Syncing plot manager…");
                backups.Backup(Path.Combine(cooked, "PlotManager.pcc"));
                PlotManagerMerge.RunPlotManagerMerge(target);
            });
        }

        if (target.Game == MEGame.LE1)
        {
            Step("Config merge", () =>
            {
                Progress("Merging LE1 config (Coalesced)…");
                foreach (var coalesced in Directory.GetFiles(cooked, "Coalesced_*.bin")) backups.Backup(coalesced);
                LE1ConfigMerge.RunCoalescedMerge(target, null, null);
            });
            Step("2DA merge", () =>
            {
                Progress("Merging 2DA tables…");
                Bio2DAMerge.RunBio2DAMerge(target);
            });
        }

        if (target.Game.SupportsSquadmateMerge() || target.Game.SupportsEmailMerge())
        {
            Step("Merge DLC", () =>
            {
                // M3 always removes the merge DLC, then rebuilds it only if something needs it.
                M3MergeDLC.RemoveMergeDLC(target);
                var mergeDLC = new M3MergeDLC(target);
                var needsSquadmate = target.Game.SupportsSquadmateMerge() && SQMOutfitMerge.NeedsMerged(target);
                var needsEmail = target.Game.SupportsEmailMerge() && ME2EmailMerge.NeedsMergedGame2(target);
                if (!needsSquadmate && !needsEmail) return;
                Progress("Building the ME3Tweaks merge DLC…");
                mergeDLC.GenerateMergeDLC();
                if (needsSquadmate)
                {
                    Progress("Synchronizing squadmate outfits…");
                    var error = SQMOutfitMerge.RunSquadmateOutfitMerge(mergeDLC, Progress);
                    if (error != null) throw new Exception(error);
                }
                if (needsEmail)
                {
                    Progress("Synchronizing emails…");
                    var error = ME2EmailMerge.RunGame2EmailMerge(mergeDLC, Progress);
                    if (error != null) throw new Exception(error);
                }
            });
        }

        Step("Shader merge", () =>
        {
            Progress("Merging shaders…");
            backups.Backup(Path.Combine(cooked, "GlobalShaderCache-PC-D3D-SM5.bin"));
            GlobalShaderMerge.RunShaderMerge(target, false);
        });

        Step("AutoTOC", () =>
        {
            Progress("Updating table of contents (AutoTOC)…");
            foreach (var toc in Directory.GetFiles(Path.Combine(target.TargetPath, "BioGame"), "PCConsoleTOC.bin", SearchOption.TopDirectoryOnly))
            {
                backups.Backup(toc);
            }
            TOCCreator.CreateTOCForGame(target.Game, gameRootOverride: target.TargetPath);
        });

        if (failures.Count > 0)
        {
            throw new Exception("Some merge steps failed: " + string.Join("; ", failures));
        }
    }

    // MARK: Game settings

    /// The game's base config files: Coalesced_*.bin (LE1/LE2, one per language) or Coalesced.bin (LE3).
    private static List<string> ConfigFiles(GameTarget target)
    {
        var cooked = Path.Combine(target.TargetPath, "BioGame", "CookedPCConsole");
        var pattern = target.Game == MEGame.LE3 ? "Coalesced.bin" : "Coalesced_*.bin";
        return MEDirectories.GetFilesOrdered(cooked, pattern).ToList();
    }

    /// Applies the user's settings (a config delta in M3's .m3cd format) on top of each config file.
    /// A clean copy of each file is kept in the state folder; whenever the game's file no longer matches
    /// what was last written here (a mod or the LE1 config merge rebuilt it), that file becomes the new
    /// clean copy. So settings survive reinstalls, and removing a setting restores the real value.
    private static void ApplySettings(GameTarget target, MEGame game, string stateDir, string deltaPath, BackupRecorder backups)
    {
        Directory.CreateDirectory(stateDir);
        CoalesceAsset delta = null;
        if (!string.IsNullOrWhiteSpace(deltaPath) && File.Exists(deltaPath))
        {
            var text = File.ReadAllText(deltaPath);
            if (!string.IsNullOrWhiteSpace(text)) delta = ConfigFileProxy.ParseIni(text);
        }

        foreach (var file in ConfigFiles(target))
        {
            var name = Path.GetFileName(file);
            var basePath = Path.Combine(stateDir, name + ".base");
            var writtenPath = Path.Combine(stateDir, name + ".written");
            var current = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(file)));
            var lastWritten = File.Exists(writtenPath) ? File.ReadAllText(writtenPath).Trim() : null;
            if (!File.Exists(basePath) || !string.Equals(current, lastWritten, StringComparison.OrdinalIgnoreCase))
            {
                File.Copy(file, basePath, overwrite: true);
            }

            backups.Backup(file);
            Progress($"Applying settings to {name}…");
            if (delta == null)
            {
                File.Copy(basePath, file, overwrite: true);
            }
            else
            {
                ConfigAssetBundle bundle;
                using (var stream = File.OpenRead(basePath))
                {
                    bundle = ConfigAssetBundle.FromSingleStream(game, stream, name);
                }
                ConfigMerge.PerformMerge(bundle, delta);
                bundle.CommitAssets(file, LocalizationFor(name));
            }
            var written = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(file)));
            File.WriteAllText(writtenPath, written);
        }
    }

    private static MELocalization LocalizationFor(string fileName)
    {
        var stem = Path.GetFileNameWithoutExtension(fileName);
        var suffix = stem.Contains('_') ? stem[(stem.LastIndexOf('_') + 1)..] : "";
        return Enum.TryParse<MELocalization>(suffix, ignoreCase: true, out var loc) ? loc : MELocalization.INT;
    }

    // MARK: Output

    private static void Progress(string message) => Console.Error.WriteLine($"PROGRESS: {message}");

    private static int Succeed(IEnumerable<string> backedUp)
    {
        ResultOut.WriteLine(JsonSerializer.Serialize(new { ok = true, backedUp, messages = Messages }));
        return 0;
    }

    private static int Fail(string error)
    {
        ResultOut.WriteLine(JsonSerializer.Serialize(new { ok = false, error, messages = Messages }));
        return 1;
    }

    private static string Required(Dictionary<string, string> options, string key) =>
        options.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException($"Missing --{key}.");

    private static Dictionary<string, string> ParseOptions(IEnumerable<string> args)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string key = null;
        foreach (var arg in args)
        {
            if (arg.StartsWith("--"))
            {
                key = arg[2..];
                result[key] = "";
            }
            else if (key != null)
            {
                result[key] = arg;
                key = null;
            }
        }
        return result;
    }
}

/// <summary>
/// Copies each base-game file to the backup folder the first time it is about to be overwritten,
/// so the Mac app can restore the original game files. Existing backups are never replaced, so the
/// backup always holds the file as it was before this app first changed it.
/// </summary>
internal sealed class BackupRecorder : IDisposable
{
    private readonly string gameRoot;
    private readonly string backupRoot;
    private readonly HashSet<string> backedUp = new(StringComparer.OrdinalIgnoreCase);

    private readonly object sync = new();

    // Merge mods save packages from several threads at once, so access is locked.
    public IReadOnlyCollection<string> BackedUp { get { lock (sync) return backedUp.ToList(); } }

    public BackupRecorder(string gameRoot, string backupRoot)
    {
        this.gameRoot = Path.GetFullPath(gameRoot);
        this.backupRoot = Path.GetFullPath(backupRoot);
        PackageSaver.BeforePackageSave = Backup;
    }

    public void Backup(string path)
    {
        if (path == null) return;
        lock (sync) BackupLocked(path);
    }

    private void BackupLocked(string path)
    {
        var full = Path.GetFullPath(path);
        var relative = Path.GetRelativePath(gameRoot, full);
        // Only base-game files need backups; Custom DLC folders are owned by mods.
        if (relative.StartsWith("..") || !File.Exists(full)) return;
        if (relative.Replace('\\', '/').StartsWith("BioGame/DLC/", StringComparison.OrdinalIgnoreCase)) return;
        if (!backedUp.Add(relative)) return;

        var destination = Path.Combine(backupRoot, relative);
        if (File.Exists(destination)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        File.Copy(full, destination);
    }

    public void Dispose() => PackageSaver.BeforePackageSave = null;
}
