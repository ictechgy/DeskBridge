// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DeskBridge.Reverse
{
    internal static class EngineCommands
    {
        internal static string[] Pair(string address)
        {
            // The upstream native pairing view generates/displays the PIN. No PIN enters wrapper logs or argv.
            return new[] { "pair", ConnectionPolicy.Address(address) };
        }
        internal static string[] Stream(string address, string resolution, int fps, int bitrate, bool fullscreen, bool macCommandKeys = false)
        {
            if (resolution != "1920x1080" && resolution != "2560x1440" && resolution != "1280x720") throw new ArgumentException("지원되지 않는 해상도입니다.");
            if (fps != 30 && fps != 60 || bitrate != 10000 && bitrate != 20000 && bitrate != 40000) throw new ArgumentException("지원되지 않는 화면 설정입니다.");
            if (macCommandKeys && !fullscreen) throw new ArgumentException("Mac Command 키 전달은 전체 화면에서만 선택하세요.");
            return new[] { "stream", ConnectionPolicy.Address(address), "Desktop", "--display-mode", fullscreen ? "fullscreen" : "windowed",
                "--resolution", resolution, "--fps", fps.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "--bitrate", bitrate.ToString(System.Globalization.CultureInfo.InvariantCulture), "--absolute-mouse", "--no-quit-after",
                "--capture-system-keys", macCommandKeys ? "fullscreen" : "never", "--no-game-optimization", "--mute-on-focus-loss", "--no-background-gamepad",
                "--audio-config", "stereo", "--no-hdr", "--no-yuv444", "--video-decoder", "auto" };
        }

        // Windows CRT quoting: quotes/backslashes are data; shell execution is never used.
        internal static string Quote(string value)
        {
            if (value == null || value.IndexOf('\0') >= 0 || value.IndexOf('\r') >= 0 || value.IndexOf('\n') >= 0) throw new ArgumentException("잘못된 실행 인수입니다.");
            var result = new StringBuilder("\""); int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') slashes++;
                else
                {
                    if (c == '"') result.Append('\\', slashes * 2 + 1);
                    else result.Append('\\', slashes);
                    result.Append(c); slashes = 0;
                }
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }
        internal static string Join(string[] args)
        { var result = new List<string>(); foreach (string item in args) result.Add(Quote(item)); return String.Join(" ", result); }
    }

    internal sealed class ProfileLease : IDisposable
    {
        internal readonly string Path;
        private readonly FileStream ownership;
        internal ProfileLease(string path, FileStream file) { Path = path; ownership = file; }
        public void Dispose() { ownership.Dispose(); }
    }

    internal static class EngineProfile
    {
        internal static ProfileLease Prepare(string root, string address)
        {
            address = ConnectionPolicy.Address(address);
            PrivateFiles.AssertPrivate(root);
            string parent = Path.Combine(root, "profiles");
            if (!Directory.Exists(parent)) PrivateFiles.CreatePrivate(parent);
            PrivateFiles.AssertPrivate(parent);
            string path = Path.Combine(parent, address.Replace('.', '_'));
            if (!Directory.Exists(path))
            {
                PrivateFiles.CreatePrivate(path);
                PrivateFiles.WriteNew(Path.Combine(path, "owner.txt"), PrivateFiles.MarkerText);
                PrivateFiles.WriteNew(Path.Combine(path, "portable.dat"), "");
            }
            PrivateFiles.AssertPrivate(path);
            CheckMutableTree(path, 0, new int[1]);
            string marker = Path.Combine(path, "owner.txt");
            if (!File.Exists(marker) || new FileInfo(marker).Length != PrivateFiles.MarkerText.Length || File.ReadAllText(marker) != PrivateFiles.MarkerText || !File.Exists(Path.Combine(path, "portable.dat")))
                throw new ReverseUserException(ReverseFailure.ProfilePolicy);
            // Another DeskBridge instance must not edit or launch the same identity/settings while it is in use.
            var ownership = new FileStream(Path.Combine(path, "in-use.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            try
            {
                if (ownership.Length != 0) throw new ReverseUserException(ReverseFailure.ProfilePolicy);
            string settingsDirectory = Path.Combine(path, "Moonlight Game Streaming Project");
            if (!Directory.Exists(settingsDirectory)) PrivateFiles.CreatePrivate(settingsDirectory);
            PrivateFiles.AssertPrivate(settingsDirectory);
            string settings = Path.Combine(settingsDirectory, "Moonlight.ini");
            string text = "";
            if (File.Exists(settings))
            {
                if (new FileInfo(settings).Length > 1024 * 1024) throw new ReverseUserException(ReverseFailure.ProfilePolicy);
                text = File.ReadAllText(settings, new UTF8Encoding(false, true));
            }
            string updated = SetPrivacySettings(text);
            string temporary = settings + ".new-" + Guid.NewGuid().ToString("N");
            try
            {
                PrivateFiles.WriteNew(temporary, updated);
                if (File.Exists(settings)) File.Replace(temporary, settings, null);
                else File.Move(temporary, settings);
            }
            finally { if (File.Exists(temporary)) { PrivateFiles.OrdinaryAncestors(temporary); File.Delete(temporary); } }
            string temp = Path.Combine(path, "temp");
            if (!Directory.Exists(temp)) PrivateFiles.CreatePrivate(temp);
            PrivateFiles.AssertPrivate(temp);
                return new ProfileLease(path, ownership);
            }
            catch { ownership.Dispose(); throw; }
        }

        internal static string SetPrivacySettings(string original)
        {
            if (original.IndexOf('\0') >= 0) throw new ReverseUserException(ReverseFailure.ProfilePolicy);
            var forced = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                { "richpresence", "false" }, { "mdns", "false" }, { "detectnetblocking", "false" },
                { "quitAppAfter", "false" }, { "backgroundgamepad", "false" } };
            var result = new List<string>(); bool general = false, inserted = false;
            foreach (string raw in original.Replace("\r\n", "\n").Split('\n'))
            {
                string line = raw.Trim();
                if (line.StartsWith("[", StringComparison.Ordinal) && line.EndsWith("]", StringComparison.Ordinal))
                {
                    general = line.Equals("[General]", StringComparison.OrdinalIgnoreCase);
                    result.Add(raw);
                    if (general && !inserted) { foreach (var pair in forced) result.Add(pair.Key + "=" + pair.Value); inserted = true; }
                    continue;
                }
                int equals = line.IndexOf('=');
                if (general && equals >= 0 && forced.ContainsKey(line.Substring(0, equals).Trim())) continue;
                if (raw.Length != 0 || result.Count != 0) result.Add(raw);
            }
            if (!inserted) { result.Add("[General]"); foreach (var pair in forced) result.Add(pair.Key + "=" + pair.Value); }
            while (result.Count > 0 && result[result.Count - 1].Length == 0) result.RemoveAt(result.Count - 1);
            return String.Join("\r\n", result) + "\r\n";
        }

        private static void CheckMutableTree(string path, int depth, int[] count)
        {
            if (depth > 8) throw new ReverseUserException(ReverseFailure.ProfilePolicy);
            PrivateFiles.OrdinaryAncestors(path);
            foreach (string item in Directory.EnumerateFileSystemEntries(path))
            {
                if (++count[0] > 4096) throw new ReverseUserException(ReverseFailure.ProfilePolicy);
                FileAttributes attributes = File.GetAttributes(item);
                if ((attributes & FileAttributes.ReparsePoint) != 0) throw new ReverseUserException(ReverseFailure.ProfilePolicy);
                if ((attributes & FileAttributes.Directory) != 0) CheckMutableTree(item, depth + 1, count);
                else
                {
                    string extension = Path.GetExtension(item).ToLowerInvariant();
                    if (Array.IndexOf(new[] { ".exe", ".dll", ".com", ".bat", ".cmd", ".ps1", ".vbs", ".js", ".qml", ".rcc", ".qmlc", ".jsc" }, extension) >= 0)
                        throw new ReverseUserException(ReverseFailure.ProfilePolicy);
                }
            }
        }
    }

    internal sealed class EngineProcess : IDisposable
    {
        private Process process;
        private IntPtr job;
        private bool disposed;
        internal async Task<int> RunAsync(EngineLease engine, string profile, string[] arguments, CancellationToken cancel)
        {
            if (process != null || disposed) throw new ReverseUserException(ReverseFailure.EngineBusy);
            PrivateFiles.OrdinaryAncestors(profile);
            var start = new ProcessStartInfo(engine.Executable, EngineCommands.Join(arguments));
            start.UseShellExecute = false; start.WorkingDirectory = profile;
            // Read no stdout, logs, pairing secrets or desktop contents. Keep all upstream UI native.
            start.CreateNoWindow = false;
            CleanEnvironment(start, engine.Directory, profile);
            job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw new ReverseUserException(ReverseFailure.EngineStart);
            var information = new JobInformation(); information.BasicLimitInformation.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE
            int size = Marshal.SizeOf(information); IntPtr memory = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(information, memory, false);
                if (!SetInformationJobObject(job, 9, memory, (uint)size)) throw new ReverseUserException(ReverseFailure.EngineStart);
            }
            finally { Marshal.FreeHGlobal(memory); }
            var completion = new TaskCompletionSource<int>();
            var child = new Process { StartInfo = start, EnableRaisingEvents = true };
            process = child;
            // Dispose can clear the owner's field after a failed job assignment while Exited is queued.
            child.Exited += delegate { try { completion.TrySetResult(child.ExitCode); } catch (InvalidOperationException) { completion.TrySetResult(-1); } };
            cancel.ThrowIfCancellationRequested();
            if (!child.Start()) throw new ReverseUserException(ReverseFailure.EngineStart);
            if (!AssignProcessToJobObject(job, child.Handle)) { Stop(); throw new ReverseUserException(ReverseFailure.EngineStart); }
            using (cancel.Register(Stop))
            {
                if (child.HasExited) completion.TrySetResult(child.ExitCode);
                int exit = await completion.Task;
                cancel.ThrowIfCancellationRequested();
                return exit;
            }
        }

        internal static void CleanEnvironment(ProcessStartInfo start, string engine, string profile)
        {
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string system = Path.Combine(windows, "System32");
            string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            // An allowlist excludes inherited Qt/QML/SDL/COM/CLR hooks, proxy overrides and PATH injection.
            start.EnvironmentVariables.Clear();
            start.EnvironmentVariables["SystemRoot"] = windows;
            start.EnvironmentVariables["WINDIR"] = windows;
            start.EnvironmentVariables["PATH"] = system + ";" + windows;
            start.EnvironmentVariables["USERPROFILE"] = userProfile;
            start.EnvironmentVariables["LOCALAPPDATA"] = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            start.EnvironmentVariables["APPDATA"] = Path.Combine(profile, "roaming");
            start.EnvironmentVariables["TEMP"] = Path.Combine(profile, "temp");
            start.EnvironmentVariables["TMP"] = Path.Combine(profile, "temp");
            start.EnvironmentVariables["QT_PLUGIN_PATH"] = engine;
            start.EnvironmentVariables["QT_QPA_PLATFORM_PLUGIN_PATH"] = Path.Combine(engine, "platforms");
            start.EnvironmentVariables["QML2_IMPORT_PATH"] = Path.Combine(engine, "qml");
            start.EnvironmentVariables["QML_IMPORT_PATH"] = Path.Combine(engine, "qml");
            start.EnvironmentVariables["QML_DISABLE_DISK_CACHE"] = "1";
            start.EnvironmentVariables["QML_DISK_CACHE_PATH"] = Path.Combine(profile, "qmlcache");
        }

        internal void Stop()
        {
            // Terminate only the local child/job created above. No remote quit/cancel request exists here.
            IntPtr ownedJob = Interlocked.Exchange(ref job, IntPtr.Zero);
            if (ownedJob != IntPtr.Zero) CloseHandle(ownedJob);
            Process child = process;
            try { if (child != null && !child.HasExited) child.Kill(); }
            catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { }
        }
        public void Dispose() { if (disposed) return; disposed = true; Stop(); Process child = Interlocked.Exchange(ref process, null); if (child != null) child.Dispose(); }

        [StructLayout(LayoutKind.Sequential)] private struct BasicLimits
        { internal long PerProcessUserTimeLimit, PerJobUserTimeLimit; internal uint LimitFlags; internal UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; internal uint ActiveProcessLimit; internal UIntPtr Affinity; internal uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters
        { internal ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
        [StructLayout(LayoutKind.Sequential)] private struct JobInformation
        { internal BasicLimits BasicLimitInformation; internal IoCounters IoInfo; internal UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(IntPtr job, int kind, IntPtr information, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    }
}
