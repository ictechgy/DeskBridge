// SPDX-License-Identifier: GPL-3.0-only
// Offline, synthetic-only checks. Compile entrypoint DeskBridge.Reverse.ReverseClientTests.
// No forms, real processes, network, clipboard, user settings or device probes are opened.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DeskBridge.Reverse
{
    public static class ReverseClientTests
    {
        private static int checks;
        public static int Main()
        {
            try { Run(); return 0; }
            catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
        }
        public static int Run()
        {
            checks = 0;
            foreach (string address in new[] { "10.0.0.1", "172.16.0.2", "172.31.255.255", "192.168.1.1", "100.64.0.1", "100.127.255.254", "169.254.20.2" })
                Check(ConnectionPolicy.Address(address) == address, "private canonical IPv4");
            foreach (string address in new[] { "", "127.0.0.1", "172.15.0.1", "172.32.0.1", "100.63.1.1", "100.128.0.1", "8.8.8.8", "192.168.1.256", "192.168.1", "192.168.01.1", "0xc0.168.1.1", "3232235777", "192.168.1.1:47989", "mac.local", "::1", "10.0.0.1/24", "10.0.0.1?x", "10.0.0.1\0", "１０.0.0.1", "10..0.1", "10.0.-1.1" })
                Reject(() => ConnectionPolicy.Address(address), "reject noncanonical/untrusted address");
            const string basis = "deskbridge://connect?v=1&name=Mac&address=192.168.1.20";
            ReverseInvitation parsed = ConnectionPolicy.Parse(basis + "&address=100.80.1.2");
            Check(parsed.Name == "Mac" && parsed.Addresses.Count == 2 && parsed.Addresses[1] == "100.80.1.2", "two address preview");
            Check(ConnectionPolicy.Parse(basis.Replace("name=Mac", "name=%EB%82%B4%20Mac")).Name == "내 Mac", "UTF8 Korean name");
            Check(ConnectionPolicy.Parse(basis.Replace("name=Mac", "name=a+b")).Name == "a+b", "query plus remains plus");
            Check(ConnectionPolicy.Parse(basis.Replace("connect?", "connect/?")).Addresses.Count == 1, "optional slash");
            foreach (string text in new[] { "https://connect?v=1&name=Mac&address=192.168.1.20", "deskbridge://user@connect?v=1&name=Mac&address=192.168.1.20",
                basis.Replace("connect?", "connect:47989?"), basis + "#fragment", basis + "&secret=x", basis + "&name=Other", basis + "&v=1", basis + "&address=192.168.1.20",
                basis.Replace("v=1", "v=2"), basis.Replace("name=Mac", "name="), basis.Replace("name=Mac", "name=%0A"), basis.Replace("name=Mac", "name=%E2%80%AEevil"),
                basis.Replace("name=Mac", "name=%FF"), basis.Replace("name=Mac", "name=%"), basis.Replace("name=Mac", "name=%u1234"), basis.Replace("name=Mac", "name=has space"),
                basis.Replace("address=192.168.1.20", "address=8.8.8.8"), basis + "&address=192.168.1.21&address=192.168.1.22&address=192.168.1.23&address=192.168.1.24&address=192.168.1.25&address=192.168.1.26&address=192.168.1.27&address=192.168.1.28",
                basis.Replace("address=", "address"), basis.Replace("name=Mac", "name=" + new string('x', 65)), basis.Replace("name=Mac", "name=" + new string('x', 1600)), basis + "&%76=1" })
                Reject(() => ConnectionPolicy.Parse(text), "reject malformed/credential/ambiguous invitation");
            Check(ConnectionPolicy.ValidName("개발용 Mac"), "Korean name");
            Check(!ConnectionPolicy.ValidName(" Mac") && !ConnectionPolicy.ValidName("Mac ") && !ConnectionPolicy.ValidName("x\u202Ey"), "name whitespace/bidi bounds");

            const string linuxLink = "deskbridge://connect?v=2&name=Linux&address=192.168.50.20&platform=linux";
            ReverseInvitation linux = ConnectionPolicy.Parse(linuxLink);
            Check(linux.Platform == HostPlatform.Linux && linux.Addresses[0] == "192.168.50.20", "Linux producer v2 role");
            ConnectionPolicy.RequireRole(linux, HostPlatform.Linux);
            ConnectionPolicy.RequireRole(parsed, HostPlatform.Mac);
            Reject(() => ConnectionPolicy.RequireRole(linux, HostPlatform.Mac), "Linux hint never enters Mac role");
            Reject(() => ConnectionPolicy.RequireRole(parsed, HostPlatform.Linux), "legacy QR cannot silently choose Linux");
            foreach (string text in new[] { linuxLink + "&platform=linux", linuxLink + "&platform=macos", linuxLink.Replace("platform=linux", "platform=other"), linuxLink.Replace("v=2", "v=1") })
                Reject(() => ConnectionPolicy.Parse(text), "reject malformed v2 role");
            foreach (bool fullscreen in new[] { false, true })
                foreach (bool request in new[] { false, true })
                    Check(!ConnectionPolicy.MacCommandAllowed(HostPlatform.Linux, fullscreen, request), "Linux never enables Mac Command/system-key capture");
            Check(ConnectionPolicy.MacCommandAllowed(HostPlatform.Mac, true, true), "Mac explicit mapping retained");

            string[] paired = EngineCommands.Pair("192.168.10.2");
            Check(paired.Length == 2 && paired[0] == "pair" && paired[1] == "192.168.10.2", "pair does not put PIN into arguments");
            foreach (bool fullscreen in new[] { false, true })
                foreach (string size in new[] { "1280x720", "1920x1080", "2560x1440" })
                {
                    string[] command = EngineCommands.Stream("100.80.20.2", size, 60, 20000, fullscreen);
                    Check(command[0] == "stream" && command[1] == "100.80.20.2" && command[2] == "Desktop", "only explicitly selected Desktop");
                    Check(Array.IndexOf(command, "--no-quit-after") >= 0 && Array.IndexOf(command, "quit") < 0 && Array.IndexOf(command, "--quit-after") < 0, "never generate remote quit command");
                    Check(Array.IndexOf(command, "--absolute-mouse") >= 0 && Array.IndexOf(command, "--no-background-gamepad") >= 0 && Array.IndexOf(command, "never") >= 0, "desktop input profile");
                }
            Reject(() => EngineCommands.Stream("10.0.0.1", "1920x1080 --quit-after", 60, 20000, true), "resolution allowlist");
            Check(Array.IndexOf(EngineCommands.Stream("10.0.0.1", "1920x1080", 60, 20000, true, true), "never") < 0,
                "explicit Mac Command mode enables fullscreen system-key capture");
            Reject(() => EngineCommands.Stream("10.0.0.1", "1920x1080", 60, 20000, false, true), "windowed cannot unexpectedly capture system keys");
            Reject(() => EngineCommands.Stream("10.0.0.1", "1920x1080", 1000, 20000, true), "FPS allowlist");
            Reject(() => EngineCommands.Stream("10.0.0.1", "1920x1080", 60, -1, true), "bitrate allowlist");
            foreach (string value in new[] { "", "simple", "with space", "a\"b", "trailing\\", "C:\\a b\\", "\\\\\"", "&%PATH%$(x);'", "한글 Mac" })
                Check(Unquote(EngineCommands.Quote(value)) == value, "Windows CRT quote roundtrip");
            Reject(() => EngineCommands.Quote("a\0b"), "NUL rejected");
            Reject(() => EngineCommands.Quote("a\r\nb"), "newline rejected");

            const string secretPath = "C:\\Users\\PRIVATE_SYNTHETIC_USER\\SECRET_SYNTHETIC_FILE";
            foreach (Exception error in new Exception[] { new IOException(secretPath), new UnauthorizedAccessException(secretPath),
                new InvalidOperationException(secretPath), new ArgumentException(secretPath), new FormatException(secretPath) })
                Check(ReverseErrors.ForOperation(error) == ReverseErrors.Fallback && !ReverseErrors.ForOperation(error).Contains(secretPath), "unexpected OS/parse errors never echo paths or raw messages");
            foreach (ReverseFailure failure in (ReverseFailure[])Enum.GetValues(typeof(ReverseFailure)))
                Check(ReverseErrors.ForOperation(new ReverseUserException(failure)) == ReverseErrors.Fixed(failure), "only authored enum domain messages are presented");
            Check(ReverseErrors.ForOperation(new ReverseUserException(ReverseFailure.EngineIntegrity)).Contains("자동으로 삭제하거나 덮어쓰지") &&
                ReverseErrors.Fixed(ReverseFailure.EngineIntegrity).Contains("profiles"), "damaged engine manual recovery preserves profile guidance");
            Check(ReverseErrors.ForOperation(new InvalidDataException(secretPath)) == ReverseErrors.QrGuidance &&
                ReverseErrors.QrGuidance.Contains("Knot-QR") && !ReverseErrors.QrGuidance.Contains(secretPath), "QR fixed Korean local copy guidance hides raw errors");
            Check(ReverseErrors.ForOperation(new FormatException("지원되는 PC 연결 링크가 아닙니다. 공유할 PC의 Knot에서 새 QR/링크를 만드세요.")) != ReverseErrors.Fallback, "exact authored validation message remains helpful");

            const string ini = "[General]\r\nrichpresence=true\r\nmdns=true\r\ndetectnetblocking=true\r\nquitAppAfter=true\r\n[hosts]\r\n1\\srvcert=SYNTHETIC_CERT\r\n1\\address=192.168.1.2\r\n[Other]\r\nrichpresence=keep\r\n";
            string updated = EngineProfile.SetPrivacySettings(ini);
            Check(updated.Contains("richpresence=false") && updated.Contains("mdns=false") && updated.Contains("detectnetblocking=false"), "privacy options forced in exact General section");
            Check(updated.Contains("quitAppAfter=false") && !updated.Contains("quitAppAfter=true"), "remote quit preference overridden");
            Check(updated.Contains("1\\srvcert=SYNTHETIC_CERT") && updated.Contains("[Other]\r\nrichpresence=keep"), "paired trust and unrelated sections preserved");
            Check(EngineProfile.SetPrivacySettings(updated) == updated, "settings override is idempotent");
            Check(EngineProfile.SetPrivacySettings("").StartsWith("[General]", StringComparison.Ordinal), "first settings file exact Qt scope");
            Reject(() => EngineProfile.SetPrivacySettings("[General]\0evil"), "NUL settings rejected");
            foreach (string name in new[] { "Moonlight.exe", "plugins/qwindows.dll", "qml/QtQuick.2/qmldir", "LICENSE.txt" }) Check(EngineStore.SafeRelativeName(name), "pinned archive relative path");
            foreach (string name in new[] { "../evil.dll", "x/../evil.dll", "/evil.dll", "C:/evil.dll", "x\\evil.dll", "x//evil.dll", "x/evil.dll:stream", "evil. ", "CON", "COM1.dll", "NUL.txt", "LPT9", "x/", "./file", "" }) Check(!EngineStore.SafeRelativeName(name), "unsafe archive path rejected");
            Check(EngineStore.SafeDownloadUri(new Uri(EnginePin.Url)), "official pinned HTTPS asset");
            foreach (string uri in new[] { "http://github.com/x", "https://github.com.evil.test/x", "https://user@github.com/x", "https://github.com:444/x", "https://github.com/x#fragment", "https://127.0.0.1/x", "https://example.com/x" })
                Check(!EngineStore.SafeDownloadUri(new Uri(uri)), "redirect destination policy");
            Dictionary<string, RuntimeEntry> manifest = EngineStore.Manifest();
            Check(manifest.Count == EnginePin.Entries.Length && manifest.ContainsKey("Moonlight.exe") && manifest.ContainsKey("portable.dat"), "complete runtime pin manifest");
            using (var stream = new MemoryStream(Encoding.ASCII.GetBytes("abc")))
                Check(EngineStore.Hash(stream, CancellationToken.None) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA256 implementation");
            using (var cancel = new CancellationTokenSource())
            using (var stream = new MemoryStream())
            {
                cancel.Cancel(); bool cancelled = false;
                try { EngineStore.Hash(stream, cancel.Token); } catch (OperationCanceledException) { cancelled = true; }
                Check(cancelled, "already cancelled verification rejects even an empty stream");
            }
            VerifyWorkerScheduling();
            var environment = new ProcessStartInfo(); environment.EnvironmentVariables.Clear();
            environment.EnvironmentVariables["z"] = "last"; environment.EnvironmentVariables["A"] = "한글";
            Check(EngineProcess.EnvironmentBlock(environment) == "A=한글\0z=last\0\0", "native environment is sorted Unicode and double NUL terminated");
            environment.EnvironmentVariables["z"] = "invalid\0value";
            Reject(() => EngineProcess.EnvironmentBlock(environment), "native environment cannot inject variables via NUL");
            Console.WriteLine("PASS reverse-client offline checks: " + checks);
            return checks;
        }

        private static void Check(bool condition, string label) { checks++; if (!condition) throw new Exception("FAIL: " + label); }
        private sealed class VerificationStream : MemoryStream
        {
            internal readonly ManualResetEventSlim Entered = new ManualResetEventSlim();
            internal readonly ManualResetEventSlim Release = new ManualResetEventSlim();
            internal int ReadThread; internal bool Closed;
            internal VerificationStream() : base(Encoding.ASCII.GetBytes("abc")) { }
            public override int Read(byte[] buffer, int offset, int count)
            {
                ReadThread = Thread.CurrentThread.ManagedThreadId; Entered.Set();
                if (!Release.Wait(5000)) throw new TimeoutException("Synthetic verification wait");
                return base.Read(buffer, offset, count);
            }
            protected override void Dispose(bool disposing) { Closed = true; base.Dispose(disposing); }
        }
        private static void VerifyWorkerScheduling()
        {
            foreach (bool requestCancel in new[] { false, true })
            using (var cancel = new CancellationTokenSource())
            {
                int caller = Thread.CurrentThread.ManagedThreadId, opener = 0;
                var stream = new VerificationStream();
                Task verification = EngineStore.VerifyArchiveAsync(() => { opener = Thread.CurrentThread.ManagedThreadId; return stream; }, 3,
                    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", cancel.Token);
                try
                {
                    Check(stream.Entered.Wait(5000) && !verification.IsCompleted, "archive verification yields while disk work is pending");
                    Check(opener != caller && stream.ReadThread != caller, "archive open and hash run off the caller thread");
                    if (requestCancel) cancel.Cancel();
                }
                finally { stream.Release.Set(); }
                bool cancelled = false;
                try { verification.GetAwaiter().GetResult(); } catch (OperationCanceledException) { cancelled = true; }
                Check(cancelled == requestCancel && stream.Closed, "verification honors cancellation and closes the archive");
                stream.Entered.Dispose(); stream.Release.Dispose();
            }
        }
        private static void Reject(Action body, string label) { bool rejected = false; try { body(); } catch (FormatException) { rejected = true; } catch (ArgumentException) { rejected = true; } catch (IOException) { rejected = true; } Check(rejected, label); }
        // Independent CRT decoder for one quoted argument; never invokes a process or shell.
        private static string Unquote(string value)
        {
            var result = new StringBuilder(); bool quoted = false;
            for (int i = 0; i < value.Length;)
            {
                int count = 0; while (i < value.Length && value[i] == '\\') { count++; i++; }
                if (i < value.Length && value[i] == '"')
                { result.Append('\\', count / 2); if (count % 2 == 1) result.Append('"'); else quoted = !quoted; i++; }
                else { result.Append('\\', count); if (i < value.Length) result.Append(value[i++]); }
            }
            if (quoted) throw new Exception("unclosed test argv");
            return result.ToString();
        }
    }
}
