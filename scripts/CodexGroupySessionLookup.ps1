if (-not ('CodexGroupy.SessionLookup' -as [type])) {
    Add-Type -AssemblyName System.Web.Extensions
    Add-Type -ReferencedAssemblies System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace CodexGroupy {
    public sealed class SessionIndexData {
        public Dictionary<string, string> Titles { get; set; }
        public Dictionary<string, string> Paths { get; set; }
    }

    public sealed class SessionMatch {
        public string ThreadId { get; private set; }
        public string LogPath { get; private set; }
        public SessionMatch(string id, string path) { ThreadId = id; LogPath = path; }
    }

    public sealed class SessionSnapshot {
        private readonly Dictionary<string, SessionMatch> byTitle =
            new Dictionary<string, SessionMatch>(StringComparer.OrdinalIgnoreCase);
        internal readonly long WriteTicks;

        internal SessionSnapshot(long writeTicks, SessionIndexData data) {
            WriteTicks = writeTicks;
            if (data == null) return;
            var ambiguous = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in data.Titles) {
                string title = TitleKey(entry.Value);
                if (String.IsNullOrEmpty(title) || ambiguous.Contains(title)) continue;
                if (byTitle.Remove(title)) {
                    ambiguous.Add(title);
                    continue;
                }
                string logPath;
                data.Paths.TryGetValue(entry.Key, out logPath);
                byTitle.Add(title, new SessionMatch(entry.Key, logPath));
            }
        }

        public static string TitleKey(string title) {
            if (String.IsNullOrWhiteSpace(title)) return null;
            string clean = Regex.Replace(Regex.Replace(title, "[\\r\\n\\t]+", " "), "\\s{2,}", " ").Trim();
            return clean.Length > 120 ? clean.Substring(0, 117).TrimEnd() + "..." : clean;
        }

        public SessionMatch FindByTitle(string caption) {
            string title = TitleKey(caption);
            SessionMatch match;
            return title != null && byTitle.TryGetValue(title, out match) ? match : null;
        }
    }

    public sealed class SessionLookup {
        private readonly string path;
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private SessionSnapshot current = new SessionSnapshot(0, null);
        private Task<SessionSnapshot> pending;
        private long nextCheck;

        public SessionLookup(string path) { this.path = path; }

        // Called by the overlay dispatcher. File I/O and JSON decoding run off that thread.
        public SessionSnapshot GetSnapshot() {
            if (pending != null && pending.IsCompleted) {
                if (pending.Status == TaskStatus.RanToCompletion && pending.Result != null)
                    current = pending.Result;
                else if (pending.IsFaulted) {
                    var ignored = pending.Exception;
                }
                pending = null;
            }
            if (pending == null && clock.ElapsedMilliseconds >= nextCheck) {
                nextCheck = clock.ElapsedMilliseconds + 500;
                long lastTicks = current.WriteTicks;
                pending = Task.Run(() => ReadSnapshot(lastTicks));
            }
            return current;
        }

        private SessionSnapshot ReadSnapshot(long lastTicks) {
            try {
                var file = new FileInfo(path);
                if (!file.Exists) return null;
                long ticks = file.LastWriteTimeUtc.Ticks;
                if (ticks == lastTicks) return null;
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var reader = new StreamReader(stream)) {
                    var serializer = new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue };
                    var data = serializer.Deserialize<SessionIndexData>(reader.ReadToEnd());
                    return data != null && data.Titles != null && data.Paths != null
                        ? new SessionSnapshot(ticks, data) : null;
                }
            } catch (IOException) { return null; }
        }
    }
}
'@
}

function New-CodexGroupySessionLookup {
    $cache = Join-Path (Split-Path $PSScriptRoot -Parent) 'work\CodexSessionLookup.json'
    [CodexGroupy.SessionLookup]::new($cache)
}
