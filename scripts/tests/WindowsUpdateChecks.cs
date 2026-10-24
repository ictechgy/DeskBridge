// SPDX-License-Identifier: GPL-3.0-only
// Compile with the actual updater sources, generated unconfigured policy and -main:WindowsUpdateChecks.
// No native updater, installer, network, registry, process wait or GUI is invoked.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using Knot.Updates;
using DeskBridge.Reverse;

internal static class WindowsUpdateChecks
{
    private static int checks;
    private static void Check(bool condition, string message)
    { checks++; if (!condition) throw new InvalidOperationException(message); }
    private static bool InvalidVersion(string value)
    { try { UpdateSecurity.VersionBuild(value); return false; } catch (InvalidDataException) { return true; } }
    private static void State(string name, bool value)
    { typeof(KnotUpdates).GetField(name, BindingFlags.NonPublic | BindingFlags.Static).SetValue(null, value); }

    private static void Main()
    {
        string[] ordered = { "0.0.0-preview.0", "0.0.0-preview.99999", "0.0.0-beta.0", "0.0.0-rc.0", "0.0.0", "0.0.1-preview.0", "0.2.0-preview.17", "0.2.0-beta.1", "0.2.0-rc.1", "0.2.0", "1.0.0-preview.0", "999.999.999" };
        for (int i = 1; i < ordered.Length; i++) Check(UpdateSecurity.VersionBuild(ordered[i]) > UpdateSecurity.VersionBuild(ordered[i - 1]), "Version ordering changed.");
        foreach (string value in new[] { "", "1.2", "01.2.3", "1.02.3", "1.2.03", "1000.0.0", "0.0.1000", "1.2.3-preview.100000", "1.2.3-preview.01", "1.2.3-preview.-1", "1.2.3-unknown.1", "1.2.3\n", " 1.2.3", "99999999999999999999999999999999999.2.3" })
            Check(InvalidVersion(value), "Malformed update version admitted.");
        string current = UpdateSecurity.VersionBuild("1.2.3-preview.1").ToString(CultureInfo.InvariantCulture);
        Check(UpdateSecurity.AllowedInstallerMetadata("Knot", "Knot Windows x64 Setup", "1.2.3-preview.2", current), "New x64 Knot installer refused.");
        foreach (string version in new[] { "1.2.3-preview.0", "1.2.3-preview.1", "1.2.2", "1.2.3-preview.100000", "1.2.3-preview.2\n" })
            Check(!UpdateSecurity.AllowedInstallerMetadata("Knot", "Knot Windows x64 Setup", version, current), "Downgrade or malformed update admitted.");
        foreach (string product in new[] { "DeskBridge", "Other", "Knot ", "" })
            Check(!UpdateSecurity.AllowedInstallerMetadata(product, "Knot Windows x64 Setup", "1.2.4", current), "Other signed product admitted.");
        foreach (string description in new[] { "Knot Windows arm64 Setup", "Knot macOS Setup", "Knot Windows x86 Setup", "" })
            Check(!UpdateSecurity.AllowedInstallerMetadata("Knot", description, "1.2.4", current), "Other platform admitted.");
        Check(!UpdateSecurity.AllowedInstallerMetadata("Knot", "Knot Windows x64 Setup", "1.2.4", "-1"), "Malformed current build admitted.");
        foreach (string value in new[] { null, "", new string('a', 63), new string('a', 65), new string('A', 64), new string('g', 64), new string('a', 64) + "\n" })
            Check(!UpdateSecurity.Digest(value), "Malformed update hash admitted.");
        Check(UpdateSecurity.Digest(new string('a', 64)), "Valid update hash refused.");
        Check(UpdateSecurity.PublisherMatches(true, new string('a', 64), new string('a', 64)), "Pinned trusted publisher refused.");
        Check(!UpdateSecurity.PublisherMatches(false, new string('a', 64), new string('a', 64)), "Untrusted Authenticode result admitted.");
        Check(!UpdateSecurity.PublisherMatches(true, new string('a', 64), new string('b', 64)), "Other publisher admitted.");
        Check(!UpdateSecurity.PublisherMatches(true, "", ""), "Unconfigured publisher admitted.");
        Check(!UpdateSecurity.PublisherMatches(true, new string('A', 64), new string('A', 64)), "Malformed publisher digest admitted.");
        using (var stream = new MemoryStream(new byte[] { 1, 2, 3 }))
        {
            string original = UpdateSecurity.Hash(stream);
            Check(stream.Position == 0 && original == "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81", "Source bytes were not hashed exactly.");
            stream.Position = 1; stream.WriteByte(4); Check(UpdateSecurity.Hash(stream) != original, "Tampering did not change the handoff digest.");
        }
        Check(UpdateSecurity.Quote("") == "\"\"", "Empty argument quoting changed.");
        Check(UpdateSecurity.Quote("a b") == "\"a b\"", "Space argument quoting changed.");
        Check(UpdateSecurity.Quote("a\"b") == "\"a\\\"b\"", "Quote argument escaping changed.");
        Check(UpdateSecurity.Quote("a\\") == "\"a\\\\\"", "Trailing slash argument escaping changed.");
        bool nul = false; try { UpdateSecurity.Quote("a\0b"); } catch (InvalidDataException) { nul = true; } Check(nul, "NUL argument admitted.");
        if (Environment.OSVersion.Platform == PlatformID.Win32NT)
        {
          string fixture = Path.Combine(Path.GetTempPath(), "knot-update-bytes-" + Guid.NewGuid().ToString("N") + ".exe");
          try
          {
            File.WriteAllBytes(fixture, new byte[] { 1, 2, 3 });
            string expected;
            using (var bytes = new MemoryStream(new byte[] { 1, 2, 3 })) expected = UpdateSecurity.Hash(bytes);
            using (var file = UpdateSecurity.OpenPinnedFile(fixture, expected))
            {
                bool blocked = false;
                try { using (var write = new FileStream(fixture, FileMode.Open, FileAccess.Write, FileShare.ReadWrite)) write.WriteByte(4); }
                catch (IOException) { blocked = true; }
                Check(blocked, "Installer lock permitted a concurrent writer.");
            }
            File.WriteAllBytes(fixture, new byte[] { 1, 2, 4 });
            bool rejected = false;
            try { using (var changed = UpdateSecurity.OpenPinnedFile(fixture, expected)) { } }
            catch (InvalidDataException) { rejected = true; }
            Check(rejected, "Changed handoff bytes admitted.");
          }
          finally { File.Delete(fixture); }
          Check(UpdateSecurity.RegisteredExecutable(@"C:\Program Files\Knot\") == @"C:\Program Files\Knot\DeskBridge-Windows.exe", "Registered custom path lost.");
          Check(UpdateSecurity.RegisteredExecutable(@"D:\Apps\My Knot") == @"D:\Apps\My Knot\DeskBridge-Windows.exe", "Custom installation path refused.");
          Check(UpdateSecurity.RegisteredExecutable(@"\\server\share") == null, "Network installation path admitted.");
          Check(UpdateSecurity.RegisteredExecutable(@"C:\Apps\..\Knot") == null, "Unnormalized registration admitted.");
          Check(UpdateSecurity.RegisteredExecutable("relative") == null, "Relative registration admitted.");
        }
        // Exercise the real adapter admission guard without starting WinSparkle. If the
        // install latch is removed, this fixture admits new activity and fails.
        State("stopped", false); State("accepting", false);
        Check(KnotUpdates.SetIdle(false), "Idle -> busy transition refused.");
        State("accepting", true); Check(!KnotUpdates.SetIdle(false), "New work admitted after update acceptance.");
        Check(!KnotUpdates.CanStartNewActivity, "Accepted update left actions enabled.");
        State("accepting", false); State("stopped", true); Check(!KnotUpdates.SetIdle(false), "New work admitted during shutdown.");
        Check(!KnotUpdates.CanStartNewActivity, "Shutdown left actions enabled.");
        State("stopped", false);
        Console.WriteLine("Windows update policy: " + checks.ToString(CultureInfo.InvariantCulture) + " checks passed; native updater and installer not run.");
    }
}
