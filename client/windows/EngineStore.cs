// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace DeskBridge.Reverse
{
    public sealed class RuntimeEntry
    {
        public readonly string Name, SHA256;
        public readonly long Bytes;
        public RuntimeEntry(string name, string sha256, long bytes) { Name = name; SHA256 = sha256; Bytes = bytes; }
    }

    internal sealed class EngineLease : IDisposable
    {
        internal readonly string Executable, Directory;
        private readonly List<FileStream> locks;
        internal EngineLease(string directory, List<FileStream> files)
        { Directory = directory; Executable = Path.Combine(directory, "Moonlight.exe"); locks = files; }
        public void Dispose() { foreach (FileStream file in locks) file.Dispose(); locks.Clear(); }
    }

    internal sealed class EngineStore
    {
        internal readonly string Root, Runtime;
        internal EngineStore() { Root = PrivateFiles.OpenRoot(); Runtime = Path.Combine(Root, "engine-" + EnginePin.Version); }
        internal bool Installed { get { return Directory.Exists(Runtime); } }

        internal async Task InstallAsync(IProgress<int> progress, CancellationToken cancel)
        {
            PrivateFiles.AssertPrivate(Root);
            if (Directory.Exists(Runtime))
            {
                using (EngineLease ignored = await Task.Run(() => Verify(cancel), cancel)) { }
                return;
            }
            string stage = Path.Combine(Root, "download-" + Guid.NewGuid().ToString("N"));
            var files = new List<string>(); var directories = new List<string>();
            bool moved = false;
            try
            {
                PrivateFiles.CreatePrivate(stage); directories.Add(stage);
                string archive = Path.Combine(stage, "download.zip");
                files.Add(archive);
                using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel))
                {
                    deadline.CancelAfter(TimeSpan.FromMinutes(10));
                    try { await DownloadAsync(archive, progress, deadline.Token); }
                    catch (OperationCanceledException)
                    { cancel.ThrowIfCancellationRequested(); throw new ReverseUserException(ReverseFailure.DownloadDeadline); }
                }
                await VerifyArchiveAsync(() => new FileStream(archive, FileMode.Open, FileAccess.Read, FileShare.Read),
                    EnginePin.Bytes, EnginePin.SHA256, cancel);
                string extracted = Path.Combine(stage, "runtime");
                PrivateFiles.CreatePrivate(extracted); directories.Add(extracted);
                try { await Task.Run(() => Extract(archive, extracted, files, directories, cancel), cancel); }
                catch (InvalidDataException) { throw new ReverseUserException(ReverseFailure.EngineArchive); }
                cancel.ThrowIfCancellationRequested();
                using (EngineLease ignored = await Task.Run(() => VerifyDirectory(extracted, cancel), cancel)) { }
                cancel.ThrowIfCancellationRequested();
                PrivateFiles.AssertPrivate(Root);
                Directory.Move(extracted, Runtime); // Same-volume, non-overwrite commit. Never replace a running or unknown install.
                moved = true;
                progress.Report(100);
            }
            finally
            {
                if (moved)
                {
                    files.RemoveAll(p => !p.EndsWith("download.zip", StringComparison.Ordinal));
                    directories.RemoveAll(p => p != stage);
                }
                PrivateFiles.CleanupCreated(files, directories);
            }
        }

        internal EngineLease Verify(CancellationToken cancel)
        { PrivateFiles.AssertPrivate(Root); return VerifyDirectory(Runtime, cancel); }

        // The opener runs on the worker too. Synthetic streams can verify scheduling and cancellation
        // without touching an existing install or requiring the production archive.
        internal static Task VerifyArchiveAsync(Func<Stream> open, long expectedBytes, string expectedHash, CancellationToken cancel)
        {
            return Task.Run(() =>
            {
                cancel.ThrowIfCancellationRequested();
                using (Stream input = open())
                    if (input.Length != expectedBytes || Hash(input, cancel) != expectedHash.ToLowerInvariant())
                        throw new ReverseUserException(ReverseFailure.EngineArchive);
            }, cancel);
        }

        private static EngineLease VerifyDirectory(string directory, CancellationToken cancel)
        {
            PrivateFiles.AssertPrivate(directory);
            Dictionary<string, RuntimeEntry> expected = Manifest();
            var actual = new List<string>();
            Enumerate(directory, "", actual, expected.Count + 64, new int[1]);
            if (actual.Count != expected.Count) throw new ReverseUserException(ReverseFailure.EngineIntegrity);
            var locks = new List<FileStream>();
            try
            {
                foreach (string name in actual)
                {
                    cancel.ThrowIfCancellationRequested();
                    RuntimeEntry entry;
                    if (!expected.TryGetValue(name, out entry)) throw new ReverseUserException(ReverseFailure.EngineIntegrity);
                    string path = Path.Combine(directory, name.Replace('/', Path.DirectorySeparatorChar));
                    var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                    locks.Add(file);
                    if (file.Length != entry.Bytes || Hash(file, cancel) != entry.SHA256.ToLowerInvariant())
                        throw new ReverseUserException(ReverseFailure.EngineIntegrity);
                }
                return new EngineLease(directory, locks);
            }
            catch { foreach (FileStream file in locks) file.Dispose(); throw; }
        }

        private static void Enumerate(string root, string relative, List<string> files, int bound, int[] entries)
        {
            string path = relative.Length == 0 ? root : Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
            PrivateFiles.OrdinaryAncestors(path);
            foreach (string item in Directory.EnumerateFileSystemEntries(path))
            {
                if (++entries[0] > 1024) throw new ReverseUserException(ReverseFailure.EngineIntegrity);
                FileAttributes attributes = File.GetAttributes(item);
                if ((attributes & FileAttributes.ReparsePoint) != 0) throw new ReverseUserException(ReverseFailure.EngineIntegrity);
                string name = (relative.Length == 0 ? "" : relative + "/") + Path.GetFileName(item);
                if ((attributes & FileAttributes.Directory) != 0)
                {
                    if (name.Length > 240) throw new ReverseUserException(ReverseFailure.EngineIntegrity);
                    Enumerate(root, name, files, bound, entries);
                }
                else { files.Add(name); if (files.Count > bound) throw new ReverseUserException(ReverseFailure.EngineIntegrity); }
            }
        }

        internal static Dictionary<string, RuntimeEntry> Manifest()
        {
            var result = new Dictionary<string, RuntimeEntry>(StringComparer.OrdinalIgnoreCase);
            long bytes = 0;
            foreach (RuntimeEntry entry in EnginePin.Entries)
            {
                if (!SafeRelativeName(entry.Name) || entry.Bytes < 0 || entry.Bytes > 64 * 1024 * 1024 || result.ContainsKey(entry.Name))
                    throw new ReverseUserException(ReverseFailure.EnginePolicy);
                if (entry.SHA256 == null || entry.SHA256.Length != 64) throw new ReverseUserException(ReverseFailure.EnginePolicy);
                foreach (char c in entry.SHA256.ToLowerInvariant()) if ("0123456789abcdef".IndexOf(c) < 0) throw new ReverseUserException(ReverseFailure.EnginePolicy);
                bytes += entry.Bytes; result.Add(entry.Name, entry);
            }
            if (result.Count > 512 || bytes > 128 * 1024 * 1024 || !result.ContainsKey("Moonlight.exe") || !result.ContainsKey("portable.dat"))
                throw new ReverseUserException(ReverseFailure.EnginePolicy);
            return result;
        }

        internal static bool SafeRelativeName(string name)
        {
            if (String.IsNullOrEmpty(name) || name.Length > 240 || name.IndexOf('\\') >= 0 || name[0] == '/' || name.IndexOf(':') >= 0) return false;
            foreach (string part in name.Split('/'))
            {
                if (part.Length == 0 || part == "." || part == ".." || part.TrimEnd('.', ' ') != part) return false;
                foreach (char c in part) if (!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || "-_. ".IndexOf(c) >= 0)) return false;
                string stem = part.Split('.')[0].ToUpperInvariant();
                if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" ||
                    stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && stem[3] >= '0' && stem[3] <= '9') return false;
            }
            return true;
        }

        private static void Extract(string archive, string destination, List<string> files, List<string> directories, CancellationToken cancel)
        {
            var expected = Manifest(); var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var allowedDirectories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string name in expected.Keys)
            {
                string parent = name;
                while (parent.LastIndexOf('/') >= 0) { parent = parent.Substring(0, parent.LastIndexOf('/')); allowedDirectories.Add(parent); }
            }
            using (ZipArchive zip = ZipFile.OpenRead(archive))
            {
                if (zip.Entries.Count > expected.Count + allowedDirectories.Count) throw new ReverseUserException(ReverseFailure.EngineArchive);
                foreach (ZipArchiveEntry item in zip.Entries)
                {
                    cancel.ThrowIfCancellationRequested();
                    string name = item.FullName;
                    bool isDirectory = name.EndsWith("/", StringComparison.Ordinal);
                    string checkedName = isDirectory ? name.Substring(0, name.Length - 1) : name;
                    if (!SafeRelativeName(checkedName) || ((item.ExternalAttributes >> 16) & 0xF000) == 0xA000)
                        throw new ReverseUserException(ReverseFailure.EngineArchive);
                    if (isDirectory) { if (!allowedDirectories.Contains(checkedName) || item.Length != 0) throw new ReverseUserException(ReverseFailure.EngineArchive); continue; }
                    RuntimeEntry entry;
                    if (!expected.TryGetValue(name, out entry) || item.Length != entry.Bytes || !seen.Add(name)) throw new ReverseUserException(ReverseFailure.EngineArchive);
                    string target = Path.Combine(destination, name.Replace('/', Path.DirectorySeparatorChar));
                    CreateParents(destination, Path.GetDirectoryName(target), directories);
                    files.Add(target);
                    using (Stream source = item.Open())
                    using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        var buffer = new byte[65536]; long count = 0; int read;
                        while ((read = source.Read(buffer, 0, buffer.Length)) != 0)
                        { cancel.ThrowIfCancellationRequested(); count += read; if (count > entry.Bytes) throw new ReverseUserException(ReverseFailure.EngineArchive); output.Write(buffer, 0, read); }
                        if (count != entry.Bytes) throw new ReverseUserException(ReverseFailure.EngineArchive);
                        output.Flush(true);
                    }
                }
            }
            if (seen.Count != expected.Count) throw new ReverseUserException(ReverseFailure.EngineArchive);
        }

        private static void CreateParents(string root, string path, List<string> directories)
        {
            if (path == root || Directory.Exists(path)) { PrivateFiles.OrdinaryAncestors(path); return; }
            CreateParents(root, Path.GetDirectoryName(path), directories);
            PrivateFiles.CreatePrivate(path); directories.Add(path);
        }

        private static async Task DownloadAsync(string path, IProgress<int> progress, CancellationToken cancel)
        {
            Uri uri = new Uri(EnginePin.Url);
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            for (int redirect = 0; redirect <= 5; redirect++)
            {
                if (!SafeDownloadUri(uri)) throw new ReverseUserException(ReverseFailure.EngineDownload);
                var request = (HttpWebRequest)WebRequest.Create(uri);
                request.AllowAutoRedirect = false; request.Proxy = null; request.Timeout = 60000; request.ReadWriteTimeout = 60000;
                request.UserAgent = "Knot-Reverse/1";
                using (cancel.Register(request.Abort))
                {
                    HttpWebResponse response;
                    using (var headers = CancellationTokenSource.CreateLinkedTokenSource(cancel))
                    {
                        headers.CancelAfter(60000);
                        using (headers.Token.Register(request.Abort))
                        {
                            try { response = (HttpWebResponse)await request.GetResponseAsync(); }
                            catch (WebException) { cancel.ThrowIfCancellationRequested(); throw new ReverseUserException(ReverseFailure.EngineDownload); }
                        }
                    }
                    using (response)
                    {
                        int code = (int)response.StatusCode;
                        if (code >= 300 && code < 400)
                        {
                            string location = response.Headers[HttpResponseHeader.Location];
                            if (String.IsNullOrEmpty(location) || !Uri.TryCreate(uri, location, out uri)) throw new ReverseUserException(ReverseFailure.EngineDownload);
                            continue;
                        }
                        if (response.StatusCode != HttpStatusCode.OK || response.ContentLength >= 0 && response.ContentLength != EnginePin.Bytes)
                            throw new ReverseUserException(ReverseFailure.EngineArchive);
                        using (Stream input = response.GetResponseStream())
                        using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                        {
                            var buffer = new byte[65536]; long total = 0;
                            while (true)
                            {
                                cancel.ThrowIfCancellationRequested();
                                int read;
                                using (var idle = CancellationTokenSource.CreateLinkedTokenSource(cancel))
                                {
                                    idle.CancelAfter(60000);
                                    using (idle.Token.Register(request.Abort))
                                    {
                                        try { read = await input.ReadAsync(buffer, 0, buffer.Length, idle.Token); }
                                        catch (Exception error)
                                        {
                                            cancel.ThrowIfCancellationRequested();
                                            if (idle.IsCancellationRequested) throw new ReverseUserException(ReverseFailure.DownloadIdle);
                                            if (error is IOException || error is WebException || error is OperationCanceledException) throw new ReverseUserException(ReverseFailure.EngineDownload);
                                            throw;
                                        }
                                    }
                                }
                                if (read == 0) break;
                                total += read;
                                if (total > EnginePin.Bytes) throw new ReverseUserException(ReverseFailure.EngineArchive);
                                await output.WriteAsync(buffer, 0, read, cancel);
                                progress.Report((int)(total * 95 / EnginePin.Bytes));
                            }
                            if (total != EnginePin.Bytes) throw new ReverseUserException(ReverseFailure.EngineDownload);
                            output.Flush(true);
                        }
                        return;
                    }
                }
            }
            throw new ReverseUserException(ReverseFailure.EngineDownload);
        }

        internal static bool SafeDownloadUri(Uri uri)
        {
            return uri.IsAbsoluteUri && uri.Scheme == "https" && uri.Port == 443 && uri.UserInfo.Length == 0 && uri.Fragment.Length == 0 &&
                (uri.Host == "github.com" || uri.Host == "release-assets.githubusercontent.com" || uri.Host == "objects.githubusercontent.com");
        }

        internal static string Hash(Stream input, CancellationToken cancel)
        {
            cancel.ThrowIfCancellationRequested();
            using (SHA256 sha = SHA256.Create())
            {
                var buffer = new byte[65536]; int count;
                while ((count = input.Read(buffer, 0, buffer.Length)) != 0) { cancel.ThrowIfCancellationRequested(); sha.TransformBlock(buffer, 0, count, null, 0); }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                return BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
            }
        }
    }
}
