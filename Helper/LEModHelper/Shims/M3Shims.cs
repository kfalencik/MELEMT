// Minimal stand-ins for the parts of ME3TweaksModManager (the WPF app) that the M3 source files
// copied into M3/ reference. They keep the copied code unchanged while removing the UI.
using System.Reflection;
using ME3TweaksModManager.modmanager.objects.alternates;

namespace ME3TweaksModManager.modmanager.localizations
{
    internal static partial class M3L
    {
        internal static string GetString(string key, params object[] args)
        {
            var text = English.TryGetValue(key, out var value) ? value : key;
            try
            {
                return args.Length == 0 ? text : string.Format(text, args);
            }
            catch (FormatException)
            {
                return $"{text} ({string.Join(", ", args)})";
            }
        }

        /// <summary>The helper has no UI: dialogs are logged so the Mac app can surface them.</summary>
        internal static void ShowDialog(object owner, string message, string title = null, object buttons = null, object image = null)
        {
            M3Log.Warning($"{title}: {message}");
        }
    }
}

namespace ME3TweaksModManager.modmanager.diagnostics
{
    /// <summary>All helper output except the final JSON result goes to stderr.</summary>
    internal static class M3Log
    {
        internal static bool Verbose;

        internal static void Information(string message, bool shouldLog = true)
        {
            if (shouldLog && Verbose) Console.Error.WriteLine($"[INF] {message}");
        }

        internal static void Warning(string message, bool shouldLog = true)
        {
            if (shouldLog) Console.Error.WriteLine($"[WRN] {message}");
        }

        internal static void Error(string message, bool shouldLog = true)
        {
            if (shouldLog) Console.Error.WriteLine($"[ERR] {message}");
        }

        internal static void Exception(Exception e, string preMessage, bool fatal = false, bool condition = true)
        {
            if (condition) Console.Error.WriteLine($"[ERR] {preMessage}{e}");
        }
    }
}

namespace ME3TweaksModManager.modmanager
{
    internal static class Settings
    {
        internal static bool LogModInstallation => diagnostics.M3Log.Verbose;
    }

    internal static class M3Utilities
    {
        internal static MemoryStream ExtractInternalFileToStream(string resourceName)
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName)
                ?? throw new FileNotFoundException($"Embedded resource not found: {resourceName}");
            var ms = new MemoryStream();
            stream.CopyTo(ms);
            ms.Position = 0;
            return ms;
        }
    }

    /// <summary>Mods are always extracted to disk before the helper runs, so this only handles disk paths.</summary>
    internal static class FilesystemInterposer
    {
        internal static string PathCombine(bool isInArchive, params string[] paths) => Path.Combine(paths);
        internal static bool FileExists(string path, object archive = null) => File.Exists(path);
    }
}

namespace ME3TweaksModManager.modmanager.memoryanalyzer
{
    internal static class M3MemoryAnalyzer
    {
        internal static void AddTrackedMemoryItem(string name, object reference) { }
    }
}

namespace ME3TweaksModManager.modmanager.objects.alternates
{
    /// <summary>Only the members TLK merge option-key validation reads.</summary>
    public class AlternateDLC
    {
        public enum AltDLCOperation { OP_NOTHING, OP_ENABLE_TLKMERGE_OPTIONKEY }
        public AltDLCOperation Operation { get; set; }
        public string LE1TLKOptionKey { get; set; }
        public string FriendlyName { get; set; }
    }
}

namespace ME3TweaksModManager.modmanager.objects
{
    public class ModJob
    {
        public enum JobHeader { BASEGAME, CUSTOMDLC, GAME1_EMBEDDED_TLK }
        public JobHeader Header { get; init; }
        public List<AlternateDLC> AlternateDLCs { get; } = new();
        /// <summary>GAME1_EMBEDDED_TLK xml files, relative to that folder (legacy, uncompressed TLK merges).</summary>
        public List<string> Game1TLKXmls { get; set; }
    }
}

namespace ME3TweaksModManager.modmanager.objects.mod
{
    /// <summary>
    /// The slice of M3's Mod class the merge code needs. The Mac app parses moddesc.ini itself and
    /// passes the relevant values on the command line.
    /// </summary>
    public partial class Mod
    {
        public const string MergeModFolderName = @"MergeMods";
        public const string Game1EmbeddedTlkFolderName = @"GAME1_EMBEDDED_TLK";
        public const string Game1EmbeddedTlkCompressedFilename = @"CombinedTLKMergeData.m3za";
        public const string MODDESC_FILENAME = @"moddesc.ini";

        public string ModName { get; init; }
        public string ModPath { get; init; }
        public MEGame Game { get; init; }
        public double ModDescTargetVersion { get; init; }

        /// <summary>Mods are extracted before install, so they're never read from an archive.</summary>
        public bool IsInArchive => false;
        public ArchiveStub Archive => null;

        public List<ModJob> InstallationJobs { get; } = new();

        public ModJob GetJob(ModJob.JobHeader header) => InstallationJobs.FirstOrDefault(x => x.Header == header);

        public sealed class ArchiveStub
        {
            public void ExtractFile(string path, Stream destination) => throw new NotSupportedException();
        }
    }
}
