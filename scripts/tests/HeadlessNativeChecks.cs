// SPDX-License-Identifier: GPL-3.0-only
// Compile together with actual HeadlessNative.cs. Never instantiate WindowsPlatform
// or call public Native methods: all device/display responses below are synthetic.
namespace Knot.Headless
{
    using System;
    using System.ComponentModel;
    using System.IO;
    using System.Reflection;
    using System.Runtime.InteropServices;
    using System.Text;
    using Microsoft.Win32.SafeHandles;

    public static class HeadlessNativeChecks
    {
        private const string Owned = @"ROOT\KNOTVDD\0123456789ABCDEF0123456789ABCDEF";
        private const string Other = @"ROOT\MTTVDD\0000";
        private const string Inf = @"C:\Program Files\KnotVirtualDisplay\MttVDD.inf";
        private const string PublishedInf = "oem42.inf";
        private static int checks;
        private static void Expect(bool value, string message) { if (!value) throw new Exception(message); checks++; }
        private static void Reject<T>(Action action, string message) where T : Exception
        {
            try { action(); }
            catch (T) { checks++; return; }
            throw new Exception(message);
        }
        private static DriverDevice Device(string id) { return new DriverDevice { InstanceId = id, HardwareIds = new[] { @"Root\MttVDD" }, DriverInf = PublishedInf, DriverVersion = Policy.DriverVersion }; }
        private sealed class SyntheticPlatform : IPlatform
        {
            internal DriverDevice[] Devices = new DriverDevice[0];
            internal MonitorRecord[] Monitors = new MonitorRecord[0];
            internal DisplayRecord[] Displays = new DisplayRecord[0];
            internal int Reads, Creates, Stages, Installs, Removes, MonitorReads, DisplayReads;
            internal string Target, InfPath, ExpectedInf;
            internal string StagedInf = PublishedInf;
            internal DriverDevice[] InstalledDevices;
            internal bool Reboot;
            internal Exception ReadFailure, StageFailure, InstallFailure, RemoveFailure;
            public DriverDevice[] ReadDriverDevices() { Reads++; if (ReadFailure != null) throw ReadFailure; return Devices; }
            public void Create(string id) { Creates++; Target = id; }
            public string Stage(string inf) { Stages++; InfPath = inf; if (StageFailure != null) throw StageFailure; return StagedInf; }
            public bool Install(string id, string inf, string expected) { Installs++; Target = id; InfPath = inf; ExpectedInf = expected; if (InstallFailure != null) throw InstallFailure; if (InstalledDevices != null) Devices = InstalledDevices; return Reboot; }
            public bool Remove(string id) { Removes++; Target = id; if (RemoveFailure != null) throw RemoveFailure; return Reboot; }
            public MonitorRecord[] ReadMonitors() { MonitorReads++; return Monitors; }
            public DisplayRecord[] ReadDisplays() { DisplayReads++; return Displays; }
        }
        private static void IdentityAndPaths()
        {
            Policy.ValidateOwnedInstance(Owned); checks++;
            foreach (string id in new[] { null, "", Other, Owned.ToLowerInvariant(), Owned + "0", Owned.Substring(0, Owned.Length - 1),
                Owned + "\n", Owned.Replace('F', 'G'), @"ROOT\KNOTVDD\..\0123456789ABCDEF0123456789ABCDEF", Owned.Replace('0', '\uff10') })
            {
                string copy = id;
                Reject<ArgumentException>(delegate { Policy.ValidateOwnedInstance(copy); }, "Accepted a noncanonical owned instance.");
            }
            Expect(Policy.IsOwnedNamespace(@"root\knotvdd\malformed"), "Malformed owned-namespace collisions must remain visible.");
            Expect(!Policy.IsOwnedNamespace(@"ROOT\KNOTVDD_EXTRA\0000"), "Namespace prefix collision was accepted.");
            foreach (string path in new[] { Inf, @"D:\Knot fixture\MttVDD.INF", @"C:\한국어\driver.inf", "C:\\" + new string('a', 252) + ".inf" })
            { Policy.ValidateInfPath(path); checks++; }
            foreach (string path in new[] { null, "", "MttVDD.inf", @"C:MttVDD.inf", @"\MttVDD.inf", @"\\server\share\a.inf", @"\\?\C:\a.inf", @"C:/a.inf",
                @"C:\x\..\a.inf", @"C:\x\.\a.inf", @"C:\x\\a.inf", @"C:\x \a.inf", @"C:\x.\a.inf", @"C:\NUL\a.inf", @"C:\COM1.inf", @"C:\CON .inf", @"C:\LPT9.foo\a.inf",
                @"C:\x\a.inf:stream", @"C:\x\a.inf.exe", @"C:\x\*.inf", "C:\\x\\a\0.inf", "C:\\x\\a\n.inf", "C:\\" + new string('a', 253) + ".inf" })
            {
                string copy = path;
                Reject<ArgumentException>(delegate { Policy.ValidateInfPath(copy); }, "Accepted an unsafe or ambiguous INF path.");
            }
            Policy.ValidateOrdinaryPath(@"C:\Knot\state.json"); checks++;
            Expect(Policy.IsVirtualHardware(new[] { @"ROOT\MTTVDD" }), "Hardware identity comparison must ignore case.");
            Expect(Policy.IsVirtualHardware(new[] { "other", "MttVDD" }), "Supported alternate exact hardware ID was missed.");
            foreach (string id in new[] { "MttVDD extra", @"Root\MttVDD_fake", "Virtual Display Driver", @"PCI\MttVDD", " MttVDD", "MttVDD\0" })
                Expect(!Policy.IsVirtualHardware(new[] { id }), "Friendly name or hardware prefix became identity evidence.");
            Expect(!Policy.IsVirtualHardware(null), "Missing hardware IDs were trusted.");
            string[] parsed = Policy.ParseMultiString(Encoding.Unicode.GetBytes("Root\\MttVDD\0MttVDD\0\0"));
            Expect(parsed.Length == 2 && parsed[0] == @"Root\MttVDD" && parsed[1] == "MttVDD", "REG_MULTI_SZ parsing changed hardware IDs.");
            Expect(Policy.ParseMultiString(new byte[4]).Length == 0, "Empty hardware list was not handled.");
            foreach (byte[] input in new[] { new byte[0], new byte[3], new byte[Policy.MaxBytes + 2], Encoding.Unicode.GetBytes("MttVDD\0"), Encoding.Unicode.GetBytes("MttVDD\0\0other\0\0") })
            {
                byte[] copy = input;
                Reject<InvalidDataException>(delegate { Policy.ParseMultiString(copy); }, "Malformed hardware list was accepted.");
            }
            Reject<DecoderFallbackException>(delegate { Policy.ParseMultiString(new byte[] { 0, 0xd8, 0, 0, 0, 0 }); }, "Invalid UTF-16 hardware ID was accepted.");
        }
        private static void Ownership()
        {
            SyntheticPlatform platform = new SyntheticPlatform();
            Controller controller = new Controller(platform);
            controller.Create(Owned);
            Expect(platform.Creates == 1 && platform.Target == Owned, "Create did not preserve the pre-journaled instance.");
            platform.Devices = new[] { Device(Owned) };
            controller.Create(Owned);
            Expect(platform.Creates == 1, "Resuming an already registered exact instance created a duplicate.");
            platform.Reboot = true;
            Expect(controller.Install(Owned, Inf, PublishedInf) && platform.Installs == 1 && platform.Target == Owned && platform.InfPath == Inf && platform.ExpectedInf == PublishedInf && platform.Stages == 1, "Install lost exact instance/path or reboot status.");
            platform.Reboot = false;
            Expect(!controller.Install(Owned, Inf, PublishedInf), "Install invented a reboot request.");
            platform.Devices = new[] { Device(Other) };
            Reject<InvalidOperationException>(delegate { controller.Create(Owned); }, "Foreign non-present MttVDD must block creation.");
            Reject<InvalidOperationException>(delegate { controller.Install(Owned, Inf, PublishedInf); }, "Foreign MttVDD must never be adopted.");
            Reject<InvalidOperationException>(delegate { controller.Remove(Owned); }, "Missing owned device caused foreign removal.");
            platform.Devices = new[] { Device(Owned), Device(Other) };
            Reject<InvalidOperationException>(delegate { controller.Create(Owned); }, "Mixed owned and foreign inventory must block creation.");
            Reject<InvalidOperationException>(delegate { controller.Install(Owned, Inf, PublishedInf); }, "Mixed inventory must block installation.");
            platform.Reboot = true;
            Expect(controller.Remove(Owned) && platform.Removes == 1 && platform.Target == Owned, "Removal failed to target only the recorded owned device.");
            platform.Devices = new[] { new DriverDevice { InstanceId = Owned, HardwareIds = new string[0] } };
            Reject<InvalidOperationException>(delegate { controller.Create(Owned); }, "Unset-hardware namespace collision must be preserved.");
            Reject<InvalidOperationException>(delegate { controller.Install(Owned, Inf, PublishedInf); }, "Unset-hardware namespace collision must not be installed.");
            Reject<InvalidOperationException>(delegate { controller.Remove(Owned); }, "Unset-hardware namespace collision must not be removed.");
            platform.Devices[0].HardwareIds = new[] { @"PCI\PhysicalGPU" };
            Reject<InvalidOperationException>(delegate { controller.Remove(Owned); }, "Owned-looking physical hardware must not be removed.");
            int previousReads = platform.Reads;
            foreach (string id in new[] { Other, Owned.ToLowerInvariant(), Owned + "\0" })
            {
                string copy = id;
                Reject<ArgumentException>(delegate { controller.Create(copy); }, "Create accepted a foreign ID.");
                Reject<ArgumentException>(delegate { controller.Install(copy, Inf, PublishedInf); }, "Install accepted a foreign ID.");
                Reject<ArgumentException>(delegate { controller.Remove(copy); }, "Remove accepted a foreign ID.");
            }
            Expect(platform.Reads == previousReads && platform.Creates == 1 && platform.Installs == 2 && platform.Removes == 1, "Rejected arguments reached native inventory or mutation.");
            Reject<ArgumentException>(delegate { controller.Install(Owned, @"\\remote\driver.inf", PublishedInf); }, "Install accepted a network INF.");
            Expect(platform.Reads == previousReads, "Invalid INF was checked after device inventory.");
            platform.Devices = new DriverDevice[0];
            Reject<InvalidOperationException>(delegate { controller.Install(Owned, Inf, PublishedInf); }, "Missing instance silently installed.");
            platform.ReadFailure = new Win32Exception(5);
            Reject<Win32Exception>(delegate { controller.Create(Owned); }, "Inventory error became an empty inventory.");
            Expect(platform.Creates == 1, "Inventory failure still created a device.");
            platform.ReadFailure = null;
            platform.Devices = new[] { Device(Owned) };
            platform.InstallFailure = new Win32Exception(5);
            Reject<Win32Exception>(delegate { controller.Install(Owned, Inf, PublishedInf); }, "Install error was reported as success.");
            platform.RemoveFailure = new Win32Exception(5);
            Reject<Win32Exception>(delegate { controller.Remove(Owned); }, "Remove error was reported as success.");
            Reject<InvalidOperationException>(delegate { Policy.ValidateExclusive(new DriverDevice[Policy.MaxItems + 1], Owned, true); }, "Unbounded inventory accepted.");
        }
        private static void PublishedPackages()
        {
            foreach (string name in new[] { "oem0.inf", PublishedInf, "oem4294967295.inf" })
            { Policy.ValidatePublishedInf(name); checks++; }
            string[] malformed = { null, "", "oem.inf", "oem01.inf", "oem00.inf", "OEM42.INF", "oem4294967296.inf", "oem99999999999.inf", "oem-1.inf", "oem+1.inf",
                "oem\uff14\uff12.inf", "oem42.inf\0", "oem42.inf ", "oem42.inf.", @"x\oem42.inf", @"C:\Windows\INF\oem42.inf", "oem42.inf:stream", "MttVDD.inf" };
            foreach (string name in malformed)
            {
                string copy = name;
                Reject<ArgumentException>(delegate { Policy.ValidatePublishedInf(copy); }, "Malformed published package identity was accepted.");
            }
            Expect(Policy.PublishedInfPath(@"C:\Windows", PublishedInf) == @"C:\Windows\INF\oem42.inf", "Published driver selection did not use the Windows INF directory.");
            Expect(Policy.PublishedInfName(@"C:\Windows", @"c:\WINDOWS\inf\OEM42.INF") == PublishedInf, "Published output path was not normalized to one OEM basename.");
            foreach (string path in new[] { @"C:\WindowsOther\INF\oem42.inf", @"C:\Windows\INForeign\oem42.inf", @"D:\Windows\INF\oem42.inf", @"C:\Temp\oem42.inf" })
            {
                string copy = path;
                Reject<InvalidDataException>(delegate { Policy.PublishedInfName(@"C:\Windows", copy); }, "SetupAPI output outside the trusted Windows INF directory was accepted.");
            }
            foreach (string path in new[] { @"C:\Windows\INF\x\oem42.inf", @"C:\Windows\INF\..\oem42.inf", @"C:\Windows\INF\oem01.inf", @"C:\Windows\INF\MttVDD.inf", @"\\remote\INF\oem42.inf" })
            {
                string copy = path;
                Reject<ArgumentException>(delegate { Policy.PublishedInfName(@"C:\Windows", copy); }, "Ambiguous published INF output was accepted.");
            }
            int calls = 0;
            string result = Policy.ReadPublishedInf(delegate(StringBuilder b, out uint required) {
                calls++; b.Append(@"C:\Windows\INF\oem42.inf"); required = (uint)b.Length + 1; return 0;
            }, @"C:\Windows");
            Expect(calls == 1 && result == PublishedInf, "Bounded staging lost the actual OEM package name.");
            string longDirectory = @"C:\" + new string('w', 130);
            string longPath = longDirectory + @"\INF\oem42.inf";
            calls = 0;
            result = Policy.ReadPublishedInf(delegate(StringBuilder b, out uint required) {
                calls++; required = (uint)longPath.Length + 1;
                if (required > b.Capacity) return 122;
                b.Append(longPath); return 0;
            }, longDirectory);
            Expect(calls == 2 && result == PublishedInf, "A bounded destination sizing retry lost package identity.");
            Reject<InvalidDataException>(delegate { Policy.ReadPublishedInf(delegate(StringBuilder b, out uint required) { required = Policy.InfPathCapacity + 1; return 122; }, @"C:\Windows"); }, "Oversized staged INF output was allocated.");
            Reject<InvalidDataException>(delegate { Policy.ReadPublishedInf(delegate(StringBuilder b, out uint required) { required = 0; return 0; }, @"C:\Windows"); }, "Empty successful staging output was accepted.");
            Reject<InvalidDataException>(delegate { Policy.ReadPublishedInf(delegate(StringBuilder b, out uint required) { required = 128; return 122; }, @"C:\Windows"); }, "Non-growing staged INF output was retried.");
            Reject<InvalidDataException>(delegate { Policy.ReadPublishedInf(delegate(StringBuilder b, out uint required) { b.Append(@"C:\Windows\INF\oem42.inf"); required = (uint)b.Length + 2; return 0; }, @"C:\Windows"); }, "Inconsistent successful output length was accepted.");
            Reject<InvalidDataException>(delegate { Policy.ReadPublishedInf(delegate(StringBuilder b, out uint required) { required = 129; return 0; }, @"C:\Windows"); }, "Successful staging exceeded its destination capacity.");
            Reject<Win32Exception>(delegate { Policy.ReadPublishedInf(delegate(StringBuilder b, out uint required) { required = 0; return 5; }, @"C:\Windows"); }, "A staging error became an absent package identity.");
            calls = 0;
            Reject<InvalidOperationException>(delegate { Policy.ReadPublishedInf(delegate(StringBuilder b, out uint required) { calls++; required = (uint)b.Capacity + 1; return 122; }, @"C:\Windows"); }, "Staged INF output was retried without a limit.");
            Expect(calls == Policy.RetryLimit, "Published INF retry limit drifted.");
            SyntheticPlatform platform = new SyntheticPlatform();
            Controller controller = new Controller(platform);
            Expect(controller.Stage(Inf) == PublishedInf && platform.Stages == 1 && platform.InfPath == Inf, "Stage did not return the platform's captured canonical package.");
            foreach (string name in malformed)
            {
                platform.StagedInf = name;
                Reject<ArgumentException>(delegate { controller.Stage(Inf); }, "Stage exposed an invalid native package name.");
            }
            int stages = platform.Stages;
            Reject<ArgumentException>(delegate { controller.Stage(@"\\remote\MttVDD.inf"); }, "Stage accepted a remote source.");
            Expect(platform.Stages == stages, "An invalid source reached native staging.");
            platform.StageFailure = new Win32Exception(5);
            Reject<Win32Exception>(delegate { controller.Stage(Inf); }, "Native staging failure was reported as success.");
        }
        private static void InstallationBinding()
        {
            SyntheticPlatform platform = new SyntheticPlatform { Devices = new[] { Device(Owned) } };
            Controller controller = new Controller(platform);
            platform.StagedInf = "oem43.inf";
            Reject<InvalidOperationException>(delegate { controller.Install(Owned, Inf, PublishedInf); }, "A newly assigned package bypassed the journaled identity.");
            Expect(platform.Stages == 1 && platform.Installs == 0, "A staging identity mismatch reached device installation.");
            int reads = platform.Reads, stages = platform.Stages;
            foreach (string name in new[] { null, "oem01.inf", "OEM42.INF", @"C:\Windows\INF\oem42.inf" })
            {
                string copy = name;
                Reject<ArgumentException>(delegate { controller.Install(Owned, Inf, copy); }, "Install accepted a noncanonical expected package name.");
            }
            Expect(platform.Reads == reads && platform.Stages == stages && platform.Installs == 0, "Malformed expected package identity reached native operations.");
            platform.StagedInf = PublishedInf;
            platform.StageFailure = new Win32Exception(5);
            Reject<Win32Exception>(delegate { controller.Install(Owned, Inf, PublishedInf); }, "Install ignored a restaging error.");
            Expect(platform.Installs == 0, "Failed restaging reached device installation.");
            platform.StageFailure = null;
            DriverDevice wrongInf = Device(Owned); wrongInf.DriverInf = "oem43.inf";
            DriverDevice wrongVersion = Device(Owned); wrongVersion.DriverVersion = "11.30.4.435";
            DriverDevice absentInf = Device(Owned); absentInf.DriverInf = null;
            DriverDevice absentVersion = Device(Owned); absentVersion.DriverVersion = null;
            DriverDevice physical = Device(Owned); physical.HardwareIds = new[] { @"PCI\PhysicalGPU" };
            foreach (DriverDevice[] after in new[] { new DriverDevice[0], new[] { Device(Other) }, new[] { Device(Owned), Device(Other) },
                new[] { wrongInf }, new[] { wrongVersion }, new[] { absentInf }, new[] { absentVersion }, new[] { physical }, new DriverDevice[] { null } })
            {
                platform.Devices = new[] { Device(Owned) };
                platform.InstalledDevices = after;
                Reject<InvalidOperationException>(delegate { controller.Install(Owned, Inf, PublishedInf); }, "Install reported success without exact post-install package identity.");
            }
            DriverDevice installed = Device(Owned); installed.DriverInf = "OEM42.INF";
            platform.Devices = new[] { Device(Owned) };
            platform.InstalledDevices = new[] { installed };
            platform.Reboot = true;
            Expect(controller.Install(Owned, Inf, PublishedInf) && platform.ExpectedInf == PublishedInf, "Exact installed package identity lost case-insensitive Windows semantics or reboot status.");
        }
        private static void WriteDriverDetail(byte[] buffer, string path)
        {
            byte[] encoded = Encoding.Unicode.GetBytes(path + "\0");
            Buffer.BlockCopy(encoded, 0, buffer, 544, encoded.Length);
        }
        private static void SelectedDriverDetails()
        {
            const string windows = @"C:\Windows";
            const string publishedPath = @"C:\Windows\INF\oem42.inf";
            ulong version = ((ulong)11 << 48) | ((ulong)30 << 32) | ((ulong)4 << 16) | 434;
            Expect(Policy.DriverVersionValue == version, "Packed selected driver version differs from the pinned four-part version.");
            int calls = 0;
            Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                calls++; Expect(BitConverter.ToUInt32(buffer, 0) == 1584, "Driver detail cbSize is not the fixed Win64 struct size.");
                required = 1590;
                if (buffer.Length < required) return 122;
                WriteDriverDetail(buffer, publishedPath); return 0;
            }, windows, PublishedInf, version);
            Expect(calls == 2, "Selected driver detail sizing was not retried within its bounded allocation.");
            Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                required = (uint)buffer.Length; WriteDriverDetail(buffer, @"c:\WINDOWS\inf\OEM42.INF"); return 0;
            }, windows, PublishedInf, version); checks++;
            calls = 0;
            Policy.ReadDriverDetail never = delegate(byte[] buffer, out uint required) { calls++; throw new Exception("Rejected driver version reached native details."); };
            foreach (ulong wrong in new[] { 0UL, version - 1, version + 1, ((ulong)12 << 48) | ((ulong)30 << 32) | ((ulong)4 << 16) | 434 })
            {
                ulong copy = wrong;
                Reject<InvalidOperationException>(delegate { Policy.ValidateSelectedDriver(never, windows, PublishedInf, copy); }, "A selected driver with an unpinned version reached installation.");
            }
            Expect(calls == 0, "Rejected selected versions reached native detail enumeration.");
            foreach (string path in new[] { @"C:\Windows\INF\oem43.inf", @"C:\Windows\INF\oem0.inf" })
            {
                string copy = path;
                Reject<InvalidOperationException>(delegate { Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                    required = (uint)buffer.Length; WriteDriverDetail(buffer, copy); return 0;
                }, windows, PublishedInf, version); }, "A selected driver with another OEM INF reached installation.");
            }
            foreach (string path in new[] { @"C:\Program Files\KnotVirtualDisplay\MttVDD.inf", @"C:\WindowsOther\INF\oem42.inf", @"D:\Windows\INF\oem42.inf" })
            {
                string copy = path;
                Reject<InvalidDataException>(delegate { Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                    required = (uint)buffer.Length; WriteDriverDetail(buffer, copy); return 0;
                }, windows, PublishedInf, version); }, "A selected driver outside the trusted system INF directory reached installation.");
            }
            foreach (string path in new[] { @"C:\Windows\INF\MttVDD.inf", @"C:\Windows\INF\oem042.inf", @"C:\Windows\INF\x\oem42.inf", @"C:\Windows\INF\oem42.inf:stream", "" })
            {
                string copy = path;
                Reject<ArgumentException>(delegate { Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                    required = (uint)buffer.Length; WriteDriverDetail(buffer, copy); return 0;
                }, windows, PublishedInf, version); }, "An ambiguous selected INF field reached installation.");
            }
            foreach (uint size in new[] { 0u, 1582u, 1585u, (uint)Policy.MaxBytes + 2 })
            {
                uint copy = size;
                Reject<InvalidDataException>(delegate { Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                    required = copy; return 122;
                }, windows, PublishedInf, version); }, "An invalid native driver detail size was allocated.");
            }
            Reject<InvalidDataException>(delegate { Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                required = (uint)buffer.Length + 2; return 0;
            }, windows, PublishedInf, version); }, "Successful driver details exceeded the allocated buffer.");
            Reject<InvalidDataException>(delegate { Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                required = (uint)buffer.Length; return 122;
            }, windows, PublishedInf, version); }, "Non-growing driver detail output was retried.");
            Reject<InvalidDataException>(delegate { Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                required = (uint)buffer.Length; buffer[0] = 0; WriteDriverDetail(buffer, publishedPath); return 0;
            }, windows, PublishedInf, version); }, "A changed native detail layout was trusted.");
            Reject<InvalidDataException>(delegate { Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                required = (uint)buffer.Length;
                for (int index = 544; index < 544 + 520; index += 2) { buffer[index] = (byte)'a'; buffer[index + 1] = 0; }
                return 0;
            }, windows, PublishedInf, version); }, "An unterminated fixed INF filename was read past its field.");
            Reject<DecoderFallbackException>(delegate { Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                required = (uint)buffer.Length; buffer[544] = 0; buffer[545] = 0xd8; return 0;
            }, windows, PublishedInf, version); }, "Malformed UTF16 in selected driver identity was accepted.");
            Reject<Win32Exception>(delegate { Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                required = 0; return 5;
            }, windows, PublishedInf, version); }, "A selected-driver detail failure became successful selection.");
            calls = 0;
            Reject<InvalidOperationException>(delegate { Policy.ValidateSelectedDriver(delegate(byte[] buffer, out uint required) {
                calls++; required = (uint)buffer.Length + 2; return 122;
            }, windows, PublishedInf, version); }, "Changing selected driver details retried without a limit.");
            Expect(calls == Policy.RetryLimit, "Selected driver detail retry bound drifted.");
        }
        private static void HeldControlLockInformation()
        {
            foreach (FileAttributes attributes in new[] { (FileAttributes)0, FileAttributes.Normal, FileAttributes.Archive | FileAttributes.Hidden })
            {
                Policy.ValidateControlLockInformation(new FileInformation { Attributes = (uint)attributes, Links = 1 }); checks++;
            }
            foreach (FileAttributes attributes in new[] { FileAttributes.Directory, FileAttributes.ReparsePoint, FileAttributes.Device,
                FileAttributes.Directory | FileAttributes.ReparsePoint, FileAttributes.Archive | FileAttributes.ReparsePoint })
            {
                FileAttributes copy = attributes;
                Reject<InvalidDataException>(delegate { Policy.ValidateControlLockInformation(new FileInformation { Attributes = (uint)copy, Links = 1 }); }, "A nonordinary held control lock was accepted.");
            }
            foreach (uint links in new[] { 0u, 2u, UInt32.MaxValue })
            {
                uint copy = links;
                Reject<InvalidDataException>(delegate { Policy.ValidateControlLockInformation(new FileInformation { Attributes = (uint)FileAttributes.Normal, Links = copy }); }, "A held control lock with missing or multiple links was accepted.");
            }
            foreach (FileInformation information in new[] {
                new FileInformation { Attributes = (uint)FileAttributes.Normal, Links = 1, SizeLow = 1 },
                new FileInformation { Attributes = (uint)FileAttributes.Normal, Links = 1, SizeLow = UInt32.MaxValue },
                new FileInformation { Attributes = (uint)FileAttributes.Normal, Links = 1, SizeHigh = 1 },
                new FileInformation { Attributes = (uint)FileAttributes.Normal, Links = 1, SizeHigh = UInt32.MaxValue, SizeLow = UInt32.MaxValue } })
            {
                FileInformation copy = information;
                Reject<InvalidDataException>(delegate { Policy.ValidateControlLockInformation(copy); }, "Nonempty held control lock metadata was accepted.");
            }
        }
        private static void Discovery()
        {
            SyntheticPlatform platform = new SyntheticPlatform();
            Controller controller = new Controller(platform);
            ScanResult empty = controller.Scan();
            Expect(empty.Devices.Length == 0 && empty.Displays.Length == 0 && platform.MonitorReads == 0 && platform.DisplayReads == 0, "Empty inventory caused unnecessary monitor access.");
            platform.Devices = new[] { Device(Owned) };
            platform.Monitors = new[] {
                new MonitorRecord { Path = @"\\?\DISPLAY#synthetic-vdd", Ancestors = new[] { @"SYNTHETIC\INTERMEDIATE\0", Owned.ToLowerInvariant(), @"HTREE\ROOT\0" } },
                new MonitorRecord { Path = @"\\?\DISPLAY#synthetic-physical", Ancestors = new[] { @"PCI\PhysicalGPU\0", @"HTREE\ROOT\0" } }
            };
            platform.Displays = new[] {
                new DisplayRecord { Path = @"\\?\DISPLAY#synthetic-vdd", Name = "unremarkable label", DisplayName = @"\\.\DISPLAY3", Active = false },
                new DisplayRecord { Path = @"\\?\DISPLAY#synthetic-physical", Name = "MttVDD Virtual Display Driver", DisplayName = @"\\.\DISPLAY1", Active = true },
                new DisplayRecord { Path = @"\\?\display#SYNTHETIC-VDD", Name = "actual synthetic target", DisplayName = @"\\.\DISPLAY4", Active = true },
                new DisplayRecord { Path = @"\\?\DISPLAY#unknown", Name = "MttVDD Virtual Display Driver", DisplayName = @"\\.\DISPLAY5", Active = true }
            };
            ScanResult scan = controller.Scan();
            Expect(scan.Devices.Length == 1 && scan.Displays.Length == 1, "Physical/unknown named displays became virtual candidates.");
            DisplayTarget target = scan.Displays[0];
            Expect(target.AdapterInstanceId == Owned && target.Active && target.DisplayName == @"\\.\DISPLAY4" && target.Name == "actual synthetic target", "Discovery lost verified adapter or preferred an inactive duplicate.");
            Array.Reverse(platform.Displays);
            Expect(controller.Scan().Displays[0].DisplayName == @"\\.\DISPLAY4", "Inactive duplicate replaced the active candidate.");
            platform.Devices[0].HardwareIds = new string[0];
            Expect(controller.Scan().Displays.Length == 0, "An owned-looking namespace alone established display identity.");
            platform.Devices[0] = Device(Owned);
            platform.Monitors[0].Ancestors = new string[65];
            Reject<InvalidDataException>(delegate { controller.Scan(); }, "Unbounded ancestry was accepted.");
            Reject<InvalidDataException>(delegate { Policy.SelectTargets(platform.Devices, new MonitorRecord[Policy.MaxItems + 1], new DisplayRecord[0]); }, "Unbounded monitor list was accepted.");
            platform.Monitors[0].Ancestors = new[] { Owned, Other };
            platform.Devices = new[] { Device(Owned), Device(Other) };
            Reject<InvalidDataException>(delegate { controller.Scan(); }, "Ambiguous PnP ancestry was accepted.");
        }
        private static void Buffers()
        {
            int calls = 0;
            byte[] bytes = Policy.ReadBounded(delegate(byte[] b, out uint type, out uint required) {
                calls++; type = 7; required = 4;
                if (b.Length == 0) return 122;
                b[0] = 42; return 0;
            }, 7, false);
            Expect(calls == 2 && bytes.Length == 4 && bytes[0] == 42, "Bounded property reader changed bytes.");
            calls = 0;
            bytes = Policy.ReadBounded(delegate(byte[] b, out uint type, out uint required) {
                calls++; type = 7; required = 4; if (b.Length != 0) b[0] = 43; return 0;
            }, 7, false);
            Expect(calls == 2 && bytes[0] == 43, "Successful size-only probe was mishandled.");
            calls = 0;
            Reject<InvalidOperationException>(delegate { Policy.ReadBounded(delegate(byte[] b, out uint type, out uint required) {
                calls++; type = 7; required = (uint)b.Length + 2; return 122;
            }, 7, false); }, "Changing property was retried indefinitely.");
            Expect(calls == Policy.RetryLimit, "Property retry bound drifted.");
            Reject<InvalidDataException>(delegate { Policy.ReadBounded(delegate(byte[] b, out uint type, out uint required) { type = 7; required = Policy.MaxBytes + 1; return 122; }, 7, false); }, "Oversized native allocation accepted.");
            Reject<InvalidDataException>(delegate { Policy.ReadBounded(delegate(byte[] b, out uint type, out uint required) { type = 7; required = 0; return 122; }, 7, false); }, "Non-growing native buffer accepted.");
            Reject<InvalidDataException>(delegate { Policy.ReadBounded(delegate(byte[] b, out uint type, out uint required) { type = 1; required = 0; return 0; }, 7, false); }, "Wrong registry property type accepted.");
            Reject<Win32Exception>(delegate { Policy.ReadBounded(delegate(byte[] b, out uint type, out uint required) { type = 0; required = 0; return 5; }, 7, true); }, "Access error became absent hardware identity.");
            Expect(Policy.ReadBounded(delegate(byte[] b, out uint type, out uint required) { type = 0; required = 0; return 13; }, 7, true) == null, "Absent hardware property was not represented.");
            Reject<Win32Exception>(delegate { Policy.ReadBounded(delegate(byte[] b, out uint type, out uint required) { type = 0; required = 0; return 2; }, 7, false); }, "Required missing property was ignored.");
            calls = 0;
            Reject<InvalidDataException>(delegate { Policy.ReadBounded(delegate(byte[] b, out uint type, out uint required) {
                type = 7; required = calls++ == 0 ? 2u : 4u; return calls == 1 ? 122 : 0;
            }, 7, false); }, "Success with a larger than allocated result was accepted.");
        }
        private static void DisplayQueries()
        {
            int calls = 0;
            ConfigPath[] paths = WindowsPlatform.QueryPaths(delegate(out uint p, out uint m) { p = 2; m = 3; return 0; },
                delegate(ref uint p, ConfigPath[] b, ref uint m, IntPtr modes) {
                    calls++; Expect(b.Length == 2 && modes != IntPtr.Zero, "Display query did not allocate bounded buffers.");
                    if (calls == 1) return 122;
                    b[0].Flags = 1; p = 1; m = 0; return 0;
                });
            Expect(calls == 2 && paths.Length == 1 && paths[0].Flags == 1, "Changing display topology was not retried and trimmed.");
            calls = 0;
            Reject<InvalidOperationException>(delegate { WindowsPlatform.QueryPaths(delegate(out uint p, out uint m) { p = 1; m = 0; return 0; },
                delegate(ref uint p, ConfigPath[] b, ref uint m, IntPtr modes) { calls++; return 122; }); }, "Display retry loop was unbounded.");
            Expect(calls == Policy.RetryLimit, "Display retry bound drifted.");
            WindowsPlatform.PathQuery never = delegate(ref uint p, ConfigPath[] b, ref uint m, IntPtr modes) { throw new Exception("Rejected size reached query."); };
            Reject<InvalidDataException>(delegate { WindowsPlatform.QueryPaths(delegate(out uint p, out uint m) { p = Policy.MaxItems + 1; m = 0; return 0; }, never); }, "Excessive path count accepted.");
            Reject<InvalidDataException>(delegate { WindowsPlatform.QueryPaths(delegate(out uint p, out uint m) { p = 0; m = Policy.MaxItems * 4 + 1; return 0; }, never); }, "Excessive mode count accepted.");
            Reject<Win32Exception>(delegate { WindowsPlatform.QueryPaths(delegate(out uint p, out uint m) { p = 0; m = 0; return 5; }, never); }, "Sizing error was ignored.");
            Reject<InvalidDataException>(delegate { WindowsPlatform.QueryPaths(delegate(out uint p, out uint m) { p = 1; m = 0; return 0; },
                delegate(ref uint p, ConfigPath[] b, ref uint m, IntPtr modes) { p = 2; return 0; }); }, "Out of bounds successful path count accepted.");
            Reject<Win32Exception>(delegate { WindowsPlatform.QueryPaths(delegate(out uint p, out uint m) { p = 1; m = 0; return 0; },
                delegate(ref uint p, ConfigPath[] b, ref uint m, IntPtr modes) { return 5; }); }, "Display query error was ignored.");
            paths = WindowsPlatform.QueryPaths(delegate(out uint p, out uint m) { p = 0; m = 0; return 0; },
                delegate(ref uint p, ConfigPath[] b, ref uint m, IntPtr modes) { Expect(b.Length == 0 && modes == IntPtr.Zero, "Zero-size display query allocated invalid storage."); return 0; });
            Expect(paths.Length == 0, "Empty display query returned invented paths.");
        }
        private static void NativeContracts()
        {
            Expect(IntPtr.Size == 8, "Native layout checks require a 64-bit test process.");
            Type[] types = { typeof(DevInfo), typeof(InterfaceData), typeof(PropertyKey), typeof(FileInformation), typeof(InstallParameters), typeof(DriverInfo), typeof(DriverDetail),
                typeof(Luid), typeof(PathSource), typeof(PathTarget), typeof(ConfigPath), typeof(InfoHeader), typeof(TargetName), typeof(SourceName) };
            int[] sizes = { 32, 32, 20, 52, 584, 1568, 1584, 8, 20, 48, 72, 20, 420, 84 };
            for (int index = 0; index < types.Length; index++) Expect(Marshal.SizeOf(types[index]) == sizes[index], "Incorrect Win64 native layout: " + types[index].Name);
            Expect(Marshal.OffsetOf(typeof(InstallParameters), "DriverPath").ToInt32() == 60, "DriverPath offset differs from Win64 SetupAPI.");
            Expect(Marshal.OffsetOf(typeof(TargetName), "Path").ToInt32() == 164, "Monitor interface path offset differs from DisplayConfig.");
            Expect(Marshal.OffsetOf(typeof(ConfigPath), "Target").ToInt32() == 20, "DisplayConfig target alignment changed.");
            Expect(Marshal.OffsetOf(typeof(DriverDetail), "InfFileName").ToInt32() == 544, "Driver detail INF filename offset differs from Win64 SetupAPI.");
            Expect(Marshal.OffsetOf(typeof(DriverDetail), "HardwareId").ToInt32() == 1576, "Driver detail variable ID offset differs from Win64 SetupAPI.");
            MethodInfo stage = typeof(Native).GetMethod("StageDriverPackage");
            Expect(stage != null && stage.ReturnType == typeof(string) && stage.GetParameters().Length == 1, "The public stage API did not return a captured package identity.");
            MethodInfo install = typeof(Native).GetMethod("InstallDevice");
            Expect(install != null && install.GetParameters().Length == 3 && install.GetParameters()[2].ParameterType == typeof(string), "A public installation path can omit the recorded package identity.");
            ParameterInfo[] copyParameters = typeof(Api).GetMethod("SetupCopyOEMInfW", BindingFlags.Static | BindingFlags.NonPublic).GetParameters();
            Expect(copyParameters[4].ParameterType == typeof(StringBuilder) && copyParameters[6].IsOut && copyParameters[6].ParameterType == typeof(uint).MakeByRefType(), "SetupAPI staging discards its bounded published filename output.");
            ParameterInfo[] detailParameters = typeof(Api).GetMethod("SetupDiGetDriverInfoDetailW", BindingFlags.Static | BindingFlags.NonPublic).GetParameters();
            Expect(detailParameters[3].ParameterType == typeof(byte[]) && detailParameters[5].IsOut && detailParameters[5].ParameterType == typeof(uint).MakeByRefType(), "Selected driver detail output does not use a bounded byte buffer and explicit required size.");
            MethodInfo heldLock = typeof(Native).GetMethod("ValidateControlLockHandle");
            Expect(heldLock != null && heldLock.ReturnType == typeof(void) && heldLock.GetParameters().Length == 1 && heldLock.GetParameters()[0].ParameterType == typeof(SafeFileHandle), "Held control lock validation does not accept the caller's live safe handle without a path reopen.");
            int imports = 0;
            foreach (MethodInfo method in typeof(Api).GetMethods(BindingFlags.Static | BindingFlags.NonPublic))
            {
                DllImportAttribute import = (DllImportAttribute)Attribute.GetCustomAttribute(method, typeof(DllImportAttribute));
                if (import == null) continue;
                imports++;
                DefaultDllImportSearchPathsAttribute search = (DefaultDllImportSearchPathsAttribute)Attribute.GetCustomAttribute(method, typeof(DefaultDllImportSearchPathsAttribute));
                Expect(search != null && search.Paths == DllImportSearchPath.System32, "Native DLL lookup is not restricted to System32: " + method.Name);
                Expect(import.Value == "setupapi.dll" || import.Value == "newdev.dll" || import.Value == "cfgmgr32.dll" || import.Value == "user32.dll" || import.Value == "kernel32.dll", "Unexpected native dependency.");
                Expect(method.Name != "SetDisplayConfig" && method.Name != "UpdateDriverForPlugAndPlayDevices" && method.Name != "DiInstallDriver", "Broad display/driver mutation was exposed.");
            }
            Expect(imports >= 25, "Native import policy checks did not inspect the actual adapter.");
        }
        public static int Run()
        {
            checks = 0;
            IdentityAndPaths(); Ownership(); PublishedPackages(); InstallationBinding(); SelectedDriverDetails(); HeldControlLockInformation(); Discovery(); Buffers(); DisplayQueries(); NativeContracts();
            return checks;
        }
        private static int Main()
        {
            int count = Run();
            Console.WriteLine("{\"status\":\"passed\",\"checks\":" + count + ",\"freshSyntheticOnly\":true,\"nativeApisInvoked\":false}");
            return 0;
        }
    }
}
