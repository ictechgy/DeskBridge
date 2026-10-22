// SPDX-License-Identifier: GPL-3.0-only
// Exact-instance SetupAPI adapter. C# 5 / .NET Framework 4.8.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Threading.Tasks;
using System.Text;

namespace Knot.Headless
{
    public sealed class DriverDevice
    {
        public string InstanceId { get; set; }
        public string[] HardwareIds { get; set; }
        public string DriverInf { get; set; }
        public string DriverVersion { get; set; }
    }

    public sealed class DisplayTarget
    {
        public string AdapterInstanceId { get; set; }
        public string Name { get; set; }
        public string DisplayName { get; set; }
        public bool Active { get; set; }
    }

    public sealed class ScanResult
    {
        public DriverDevice[] Devices { get; set; }
        public DisplayTarget[] Displays { get; set; }
    }

    // The public surface never accepts a native implementation from callers.
    public static class Native
    {
        public static DriverDevice[] ReadDriverDevices() { return new WindowsPlatform().ReadDriverDevices(); }
        public static void CreateDevice(string instanceId) { new Controller(new WindowsPlatform()).Create(instanceId); }
        public static bool InstallDevice(string instanceId, string protectedInfPath) { return new Controller(new WindowsPlatform()).Install(instanceId, protectedInfPath); }
        public static bool RemoveDevice(string instanceId) { return new Controller(new WindowsPlatform()).Remove(instanceId); }
        public static DisplayTarget[] FindDisplays() { return new Controller(new WindowsPlatform()).Scan().Displays; }
        public static Task<ScanResult> ScanAsync() { return Task.Run(delegate { return new Controller(new WindowsPlatform()).Scan(); }); }
        public static int GetFileLinkCount(string path) { return WindowsPlatform.FileLinkCount(path); }
    }

    internal sealed class MonitorRecord
    {
        internal string Path;
        internal string[] Ancestors;
    }
    internal sealed class DisplayRecord
    {
        internal string Path, Name, DisplayName;
        internal bool Active;
    }
    internal interface IPlatform
    {
        DriverDevice[] ReadDriverDevices();
        void Create(string instanceId);
        bool Install(string instanceId, string infPath);
        bool Remove(string instanceId);
        MonitorRecord[] ReadMonitors();
        DisplayRecord[] ReadDisplays();
    }

    internal sealed class Controller
    {
        private readonly IPlatform platform;
        internal Controller(IPlatform platform) { this.platform = platform; }
        internal void Create(string instanceId)
        {
            Policy.ValidateOwnedInstance(instanceId);
            DriverDevice[] devices = platform.ReadDriverDevices();
            Policy.ValidateExclusive(devices, instanceId, true);
            // Registration may have succeeded before a previous process stopped.
            // The caller's durable journal identifies the only resumable instance.
            if (devices.Length == 0) platform.Create(instanceId);
        }
        internal bool Install(string instanceId, string infPath)
        {
            Policy.ValidateOwnedInstance(instanceId);
            Policy.ValidateInfPath(infPath);
            Policy.ValidateExclusive(platform.ReadDriverDevices(), instanceId, false);
            return platform.Install(instanceId, infPath);
        }
        internal bool Remove(string instanceId)
        {
            Policy.ValidateOwnedInstance(instanceId);
            // The native backend reopens this exact instance and rechecks its
            // class and hardware IDs immediately before the destructive call.
            DriverDevice[] devices = platform.ReadDriverDevices();
            foreach (DriverDevice device in devices)
                if (String.Equals(device.InstanceId, instanceId, StringComparison.OrdinalIgnoreCase))
                {
                    if (!Policy.IsVirtualHardware(device.HardwareIds)) throw new InvalidOperationException("Device hardware identity changed.");
                    return platform.Remove(instanceId);
                }
            throw new InvalidOperationException("The recorded virtual display device is absent; no device was removed.");
        }
        internal ScanResult Scan()
        {
            DriverDevice[] devices = platform.ReadDriverDevices();
            DisplayTarget[] displays = devices.Length == 0 ? new DisplayTarget[0] :
                Policy.SelectTargets(devices, platform.ReadMonitors(), platform.ReadDisplays());
            return new ScanResult { Devices = devices, Displays = displays };
        }
    }

    internal static class Policy
    {
        internal const int MaxItems = 4096, MaxBytes = 65536, MaxChars = 4096, RetryLimit = 4;
        internal const string HardwareId = @"Root\MttVDD";
        private static readonly Encoding Utf16 = new UnicodeEncoding(false, false, true);
        internal static bool IsVirtualHardware(string[] hardwareIds)
        {
            if (hardwareIds == null) return false;
            foreach (string id in hardwareIds)
                if (String.Equals(id, HardwareId, StringComparison.OrdinalIgnoreCase) || String.Equals(id, "MttVDD", StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }
        internal static void ValidateOwnedInstance(string value)
        {
            const string prefix = @"ROOT\KNOTVDD\";
            if (value == null || value.Length != prefix.Length + 32 || !value.StartsWith(prefix, StringComparison.Ordinal))
                throw new ArgumentException("Expected the exact journaled Knot device instance ID.");
            for (int i = prefix.Length; i < value.Length; i++)
                if (!(value[i] >= '0' && value[i] <= '9') && !(value[i] >= 'A' && value[i] <= 'F'))
                    throw new ArgumentException("Knot device instance IDs require 32 uppercase hexadecimal characters.");
        }
        internal static bool IsOwnedNamespace(string value)
        {
            return value != null && value.StartsWith(@"ROOT\KNOTVDD\", StringComparison.OrdinalIgnoreCase);
        }
        internal static void ValidateInfPath(string path)
        {
            ValidateOrdinaryPath(path);
            if (!path.EndsWith(".inf", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Expected an INF file.");
        }
        internal static void ValidateOrdinaryPath(string path)
        {
            if (String.IsNullOrEmpty(path) || path.Length > 259 || path.Length < 4 ||
                !((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) || path[1] != ':' || path[2] != '\\') throw new ArgumentException("Expected an ordinary absolute local INF path.");
            Utf16.GetByteCount(path);
            for (int i = 2; i < path.Length; i++)
                if (path[i] < 32 || ":/*?\"<>|".IndexOf(path[i]) >= 0) throw new ArgumentException("Invalid INF path character.");
            string[] components = path.Substring(3).Split('\\');
            foreach (string part in components)
            {
                if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(".", StringComparison.Ordinal) || part.EndsWith(" ", StringComparison.Ordinal))
                    throw new ArgumentException("Invalid INF path component.");
                string stem = part.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
                if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" ||
                    (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && stem[3] >= '0' && stem[3] <= '9'))
                    throw new ArgumentException("An INF path cannot contain a DOS device name.");
            }
        }
        internal static void ValidateExclusive(DriverDevice[] devices, string instanceId, bool allowAbsent)
        {
            if (devices == null || devices.Length > MaxItems) throw new InvalidOperationException("Invalid virtual display inventory.");
            if (devices.Length == 0 && allowAbsent) return;
            if (devices.Length != 1 || devices[0] == null || !Policy.IsVirtualHardware(devices[0].HardwareIds) ||
                !String.Equals(devices[0].InstanceId, instanceId, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Another or unrecognized MttVDD device exists, or the recorded device is missing.");
        }
        internal static string[] ParseMultiString(byte[] data)
        {
            if (data == null || data.Length < 4 || data.Length > MaxBytes || (data.Length & 1) != 0) throw new InvalidDataException("Malformed hardware ID property.");
            string value = Utf16.GetString(data);
            if (!value.EndsWith("\0\0", StringComparison.Ordinal)) throw new InvalidDataException("Unterminated hardware ID property.");
            value = value.Substring(0, value.Length - 2);
            if (value.Length == 0) return new string[0];
            string[] values = value.Split('\0');
            if (values.Length > MaxItems) throw new InvalidDataException("Too many hardware IDs.");
            foreach (string item in values) ValidateText(item, MaxChars, false);
            return values;
        }
        internal static void ValidateText(string value, int limit, bool emptyAllowed)
        {
            if (value == null || value.Length > limit || (!emptyAllowed && value.Length == 0) || value.IndexOf('\0') >= 0)
                throw new InvalidDataException("Invalid bounded native string.");
            // Also reject unpaired UTF-16 surrogates before hashing or marshalling.
            Utf16.GetByteCount(value);
        }
        internal static DisplayTarget[] SelectTargets(DriverDevice[] devices, MonitorRecord[] monitors, DisplayRecord[] paths)
        {
            if (devices == null || monitors == null || paths == null || devices.Length > MaxItems || monitors.Length > MaxItems || paths.Length > MaxItems)
                throw new InvalidDataException("Display inventory exceeds its limit.");
            Dictionary<string, string> adapters = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (DriverDevice device in devices)
                if (device != null && IsVirtualHardware(device.HardwareIds)) adapters.Add(device.InstanceId, device.InstanceId);
            Dictionary<string, MonitorRecord> byPath = new Dictionary<string, MonitorRecord>(StringComparer.OrdinalIgnoreCase);
            foreach (MonitorRecord monitor in monitors)
            {
                ValidateText(monitor.Path, MaxChars, false);
                if (monitor.Ancestors == null || monitor.Ancestors.Length > 64) throw new InvalidDataException("Invalid PnP ancestry.");
                byPath.Add(monitor.Path, monitor);
            }
            Dictionary<string, DisplayTarget> targets = new Dictionary<string, DisplayTarget>(StringComparer.OrdinalIgnoreCase);
            foreach (DisplayRecord path in paths)
            {
                MonitorRecord monitor;
                if (String.IsNullOrEmpty(path.Path) || !byPath.TryGetValue(path.Path, out monitor)) continue;
                string adapter = null;
                foreach (string ancestor in monitor.Ancestors)
                {
                    string match;
                    if (!adapters.TryGetValue(ancestor, out match)) continue;
                    if (adapter != null && !String.Equals(adapter, match, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Ambiguous monitor ancestry.");
                    adapter = match;
                }
                if (adapter == null) continue; // A friendly name is never identity evidence.
                DisplayTarget old;
                if (targets.TryGetValue(path.Path, out old) && old.Active) continue;
                targets[path.Path] = new DisplayTarget { AdapterInstanceId = adapter, Name = path.Name, DisplayName = path.DisplayName,
                    Active = path.Active };
            }
            DisplayTarget[] result = new DisplayTarget[targets.Count];
            targets.Values.CopyTo(result, 0);
            Array.Sort(result, delegate(DisplayTarget left, DisplayTarget right) { return StringComparer.Ordinal.Compare(left.DisplayName, right.DisplayName); });
            return result;
        }
        internal delegate int ReadBuffer(byte[] buffer, out uint type, out uint required);
        internal static byte[] ReadBounded(ReadBuffer reader, uint expectedType, bool optional)
        {
            byte[] buffer = new byte[0];
            for (int attempt = 0; attempt < RetryLimit; attempt++)
            {
                uint type, required;
                int status = reader(buffer, out type, out required);
                if (optional && (status == 2 || status == 13 || status == 1168)) return null;
                if (required > MaxBytes) throw new InvalidDataException("Native property exceeds its size limit.");
                if (status == 0)
                {
                    if (type != expectedType) throw new InvalidDataException("Native property type mismatch.");
                    if (buffer.Length == 0 && required > 0) { buffer = new byte[(int)required]; continue; }
                    if (required > buffer.Length) throw new InvalidDataException("Native property length mismatch.");
                    Array.Resize(ref buffer, (int)required);
                    return buffer;
                }
                if (status != 122 && status != 234) throw new Win32Exception(status, "Reading a bounded device property failed.");
                if (required == 0 || required <= buffer.Length) throw new InvalidDataException("Native property buffer did not grow.");
                buffer = new byte[(int)required];
            }
            throw new InvalidOperationException("Device property kept changing; retry limit reached.");
        }
    }

    internal sealed class WindowsPlatform : IPlatform
    {
        internal static readonly Guid DisplayClass = new Guid("4d36e968-e325-11ce-bfc1-08002be10318");
        private static readonly Guid MonitorInterface = new Guid("e6f07b5f-ee97-4a90-b076-33f57bf4eaa7");
        private static readonly IntPtr Invalid = new IntPtr(-1);
        private const uint CompatibleDriver = 2;
        internal WindowsPlatform()
        { RequireWindows(); }
        private static void RequireWindows()
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
                throw new PlatformNotSupportedException("Virtual display management requires 64-bit Windows.");
        }
        internal static int FileLinkCount(string path)
        {
            Policy.ValidateOrdinaryPath(path);
            RequireWindows();
            using (SafeFileHandle file = Api.CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero))
            {
                if (file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Opening protected file metadata failed.");
                FileInformation information;
                Check(Api.GetFileInformationByHandle(file, out information), "Reading protected file metadata failed.");
                if ((information.Attributes & (uint)(FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0 || information.Links == 0 || information.Links > Int32.MaxValue)
                    throw new InvalidDataException("Expected an ordinary protected file with a valid link count.");
                return (int)information.Links;
            }
        }
        private static void Check(bool success, string action) { if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), action); }
        private static IntPtr CheckHandle(IntPtr handle) { if (handle == Invalid || handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Opening a device information set failed."); return handle; }
        private static DevInfo EmptyDevice() { return new DevInfo { Size = (uint)Marshal.SizeOf(typeof(DevInfo)) }; }
        private static IntPtr OpenClass(Guid guid, uint flags) { return CheckHandle(Api.SetupDiGetClassDevsW(ref guid, null, IntPtr.Zero, flags)); }
        private static string InstanceId(IntPtr set, ref DevInfo device)
        {
            StringBuilder buffer = new StringBuilder(Policy.MaxChars + 1);
            uint required;
            Check(Api.SetupDiGetDeviceInstanceIdW(set, ref device, buffer, (uint)buffer.Capacity, out required), "Reading the device instance ID failed.");
            if (required == 0 || required > buffer.Capacity) throw new InvalidDataException("Invalid device instance ID length.");
            string value = buffer.ToString();
            Policy.ValidateText(value, Policy.MaxChars, false);
            if (required != value.Length + 1) throw new InvalidDataException("Inconsistent device instance ID length.");
            return value;
        }
        private static string[] Hardware(IntPtr set, DevInfo device)
        {
            byte[] bytes = Policy.ReadBounded(delegate(byte[] buffer, out uint type, out uint required) {
                return Api.SetupDiGetDeviceRegistryPropertyW(set, ref device, 1, out type, buffer, (uint)buffer.Length, out required) ? 0 : Marshal.GetLastWin32Error();
            }, 7, true);
            return bytes == null ? new string[0] : Policy.ParseMultiString(bytes);
        }
        private static string DriverProperty(IntPtr set, DevInfo device, uint propertyId)
        {
            PropertyKey key = new PropertyKey { Format = new Guid("a8b865dd-2e3d-4094-ad97-e593a70c75d6"), Id = propertyId };
            byte[] bytes = Policy.ReadBounded(delegate(byte[] buffer, out uint type, out uint required) {
                return Api.SetupDiGetDevicePropertyW(set, ref device, ref key, out type, buffer, (uint)buffer.Length, out required, 0) ? 0 : Marshal.GetLastWin32Error();
            }, 18, true); // DEVPROP_TYPE_STRING
            if (bytes == null) return null;
            if (bytes.Length < 2 || (bytes.Length & 1) != 0 || bytes[bytes.Length - 1] != 0 || bytes[bytes.Length - 2] != 0) throw new InvalidDataException("Malformed driver property.");
            string value = new UnicodeEncoding(false, false, true).GetString(bytes, 0, bytes.Length - 2);
            Policy.ValidateText(value, Policy.MaxChars, true);
            return value;
        }
        public DriverDevice[] ReadDriverDevices()
        {
            IntPtr set = OpenClass(DisplayClass, 0); // Deliberately includes non-present instances.
            try
            {
                List<DriverDevice> result = new List<DriverDevice>();
                for (uint index = 0; index <= Policy.MaxItems; index++)
                {
                    DevInfo device = EmptyDevice();
                    if (!Api.SetupDiEnumDeviceInfo(set, index, ref device))
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == 259) return result.ToArray();
                        throw new Win32Exception(error, "Display-class inventory failed.");
                    }
                    if (index == Policy.MaxItems) throw new InvalidDataException("Display-class inventory exceeds its limit.");
                    string[] ids = Hardware(set, device);
                    string instanceId = InstanceId(set, ref device);
                    if (Policy.IsVirtualHardware(ids) || Policy.IsOwnedNamespace(instanceId)) result.Add(new DriverDevice { InstanceId = instanceId, HardwareIds = ids,
                        DriverInf = DriverProperty(set, device, 5), DriverVersion = DriverProperty(set, device, 3) });
                }
                throw new InvalidOperationException("Unreachable inventory state.");
            }
            finally { Api.SetupDiDestroyDeviceInfoList(set); }
        }
        private static DevInfo OpenOwned(IntPtr set, string instanceId)
        {
            Policy.ValidateOwnedInstance(instanceId);
            DevInfo device = EmptyDevice();
            Check(Api.SetupDiOpenDeviceInfoW(set, instanceId, IntPtr.Zero, 0, ref device), "Opening the recorded Knot instance failed.");
            if (device.ClassGuid != DisplayClass || !String.Equals(InstanceId(set, ref device), instanceId, StringComparison.OrdinalIgnoreCase) || !Policy.IsVirtualHardware(Hardware(set, device)))
                throw new InvalidOperationException("The recorded instance no longer has the expected display class and hardware ID.");
            return device;
        }
        public void Create(string instanceId)
        {
            Policy.ValidateOwnedInstance(instanceId);
            Guid guid = DisplayClass;
            IntPtr set = CheckHandle(Api.SetupDiCreateDeviceInfoList(ref guid, IntPtr.Zero));
            try
            {
                DevInfo device = EmptyDevice();
                // Flags=0 preserves the full pre-journaled ID. Never DICD_GENERATE_ID.
                Check(Api.SetupDiCreateDeviceInfoW(set, instanceId, ref guid, "Knot Virtual Display", IntPtr.Zero, 0, ref device), "Creating the exact Knot instance failed.");
                byte[] hardware = Encoding.Unicode.GetBytes(Policy.HardwareId + "\0\0");
                Check(Api.SetupDiSetDeviceRegistryPropertyW(set, ref device, 1, hardware, (uint)hardware.Length), "Setting the virtual display hardware ID failed.");
                Check(Api.SetupDiCallClassInstaller(0x19, set, ref device), "Registering the exact Knot instance failed."); // DIF_REGISTERDEVICE
                if (!String.Equals(InstanceId(set, ref device), instanceId, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Windows registered an unexpected instance ID.");
            }
            finally { Api.SetupDiDestroyDeviceInfoList(set); }
        }
        public bool Install(string instanceId, string infPath)
        {
            Policy.ValidateInfPath(infPath);
            // The script validates protected ownership, ACL, catalog and pinned
            // contents. This layer additionally rejects reparse/filesystem aliases.
            string checkPath = infPath;
            bool first = true;
            while (checkPath != null)
            {
                FileAttributes attributes = File.GetAttributes(checkPath);
                if ((attributes & FileAttributes.ReparsePoint) != 0 || (first && (attributes & FileAttributes.Directory) != 0))
                    throw new InvalidDataException("Driver INF must be an ordinary file under ordinary directories.");
                first = false;
                checkPath = Path.GetDirectoryName(checkPath);
            }
            Guid guid = DisplayClass;
            IntPtr set = CheckHandle(Api.SetupDiCreateDeviceInfoList(ref guid, IntPtr.Zero));
            bool built = false;
            DevInfo device = EmptyDevice();
            try
            {
                device = OpenOwned(set, instanceId);
                // DiInstallDevice requires a package already in the driver store.
                // Staging does not enumerate or update matching device instances.
                Check(Api.SetupCopyOEMInfW(infPath, null, 1, 0, IntPtr.Zero, 0, IntPtr.Zero, IntPtr.Zero), "Staging the verified driver package failed.");
                InstallParameters parameters = new InstallParameters { Size = (uint)Marshal.SizeOf(typeof(InstallParameters)) };
                Check(Api.SetupDiGetDeviceInstallParamsW(set, ref device, ref parameters), "Reading device install parameters failed.");
                parameters.Flags = (parameters.Flags & ~0x00080000u) | 0x80010000u; // Single INF, preserve root IDs; never use a class-wide driver list.
                parameters.FlagsEx |= 0x20000800; // Include PnP drivers; restart only this instance, never other devices using the driver.
                parameters.DriverPath = infPath;
                Check(Api.SetupDiSetDeviceInstallParamsW(set, ref device, ref parameters), "Setting the single-INF driver selection failed.");
                Check(Api.SetupDiBuildDriverInfoList(set, ref device, CompatibleDriver), "Building this instance's compatible driver list failed.");
                built = true;
                DriverInfo selected = new DriverInfo { Size = (uint)Marshal.SizeOf(typeof(DriverInfo)) };
                Check(Api.SetupDiEnumDriverInfoW(set, ref device, CompatibleDriver, 0, ref selected), "The protected INF has no matching driver for this instance.");
                DriverInfo extra = new DriverInfo { Size = (uint)Marshal.SizeOf(typeof(DriverInfo)) };
                if (Api.SetupDiEnumDriverInfoW(set, ref device, CompatibleDriver, 1, ref extra)) throw new InvalidOperationException("The protected INF has ambiguous compatible drivers.");
                int error = Marshal.GetLastWin32Error();
                if (error != 259) throw new Win32Exception(error, "Checking the compatible driver list failed.");
                // This API installs only this DEVINFO element. Hardware-wide APIs
                // such as UpdateDriverForPlugAndPlayDevices must never be used.
                bool reboot;
                Check(Api.DiInstallDevice(IntPtr.Zero, set, ref device, ref selected, 0, out reboot), "Installing the selected driver on the exact Knot instance failed.");
                return reboot;
            }
            finally
            {
                if (built) Api.SetupDiDestroyDriverInfoList(set, ref device, CompatibleDriver);
                Api.SetupDiDestroyDeviceInfoList(set);
            }
        }
        public bool Remove(string instanceId)
        {
            Guid guid = DisplayClass;
            IntPtr set = CheckHandle(Api.SetupDiCreateDeviceInfoList(ref guid, IntPtr.Zero));
            try
            {
                DevInfo device = OpenOwned(set, instanceId);
                bool reboot;
                Check(Api.DiUninstallDevice(IntPtr.Zero, set, ref device, 0, out reboot), "Removing the exact Knot instance failed.");
                return reboot;
            }
            finally { Api.SetupDiDestroyDeviceInfoList(set); }
        }
        private static string[] Ancestors(uint child)
        {
            List<string> result = new List<string>();
            HashSet<uint> visited = new HashSet<uint>();
            for (int depth = 0; depth < 64; depth++)
            {
                uint parent;
                uint status = Api.CM_Get_Parent(out parent, child, 0);
                if (status == 13) return result.ToArray(); // CR_NO_SUCH_DEVNODE: reached root/non-present boundary.
                if (status != 0) throw new InvalidOperationException("Reading PnP ancestry failed: " + status.ToString());
                if (!visited.Add(parent)) throw new InvalidDataException("Cyclic PnP ancestry.");
                StringBuilder id = new StringBuilder(Policy.MaxChars + 1);
                status = Api.CM_Get_Device_IDW(parent, id, (uint)id.Capacity, 0);
                if (status != 0) throw new InvalidOperationException("Reading a PnP ancestor ID failed: " + status.ToString());
                string value = id.ToString();
                Policy.ValidateText(value, Policy.MaxChars, false);
                result.Add(value);
                child = parent;
            }
            throw new InvalidDataException("PnP ancestry exceeds its depth limit.");
        }
        public MonitorRecord[] ReadMonitors()
        {
            IntPtr set = OpenClass(MonitorInterface, 0x10); // DIGCF_DEVICEINTERFACE, includes non-present.
            try
            {
                List<MonitorRecord> result = new List<MonitorRecord>();
                for (uint index = 0; index <= Policy.MaxItems; index++)
                {
                    Guid guid = MonitorInterface;
                    InterfaceData data = new InterfaceData { Size = (uint)Marshal.SizeOf(typeof(InterfaceData)) };
                    if (!Api.SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, index, ref data))
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == 259) return result.ToArray();
                        throw new Win32Exception(error, "Enumerating monitor interfaces failed.");
                    }
                    if (index == Policy.MaxItems) throw new InvalidDataException("Monitor interface inventory exceeds its limit.");
                    DevInfo device = EmptyDevice();
                    uint required;
                    bool probe = Api.SetupDiGetDeviceInterfaceDetailW(set, ref data, IntPtr.Zero, 0, out required, ref device);
                    int probeError = Marshal.GetLastWin32Error();
                    if (probe || probeError != 122 || required < 8 || (required & 1) != 0 || required > 4 + 2 * (Policy.MaxChars + 1)) throw new InvalidDataException("Invalid monitor interface detail size.");
                    IntPtr detail = Marshal.AllocHGlobal((int)required);
                    try
                    {
                        Marshal.WriteInt32(detail, 8); // sizeof SP_DEVICE_INTERFACE_DETAIL_DATA_W on Win64; path offset remains 4.
                        uint actual;
                        Check(Api.SetupDiGetDeviceInterfaceDetailW(set, ref data, detail, required, out actual, ref device), "Reading monitor interface detail failed.");
                        if (actual > required || actual < 6 || (actual & 1) != 0) throw new InvalidDataException("Monitor interface detail changed size.");
                        int chars = ((int)actual - 4) / 2;
                        string path = Marshal.PtrToStringUni(IntPtr.Add(detail, 4), chars);
                        int end = path.IndexOf('\0');
                        if (end < 0) throw new InvalidDataException("Unterminated monitor interface path.");
                        path = path.Substring(0, end);
                        Policy.ValidateText(path, Policy.MaxChars, false);
                        result.Add(new MonitorRecord { Path = path, Ancestors = Ancestors(device.DevInst) });
                    }
                    finally { Marshal.FreeHGlobal(detail); }
                }
                throw new InvalidOperationException("Unreachable monitor inventory state.");
            }
            finally { Api.SetupDiDestroyDeviceInfoList(set); }
        }
        internal delegate int PathSizes(out uint paths, out uint modes);
        internal delegate int PathQuery(ref uint paths, ConfigPath[] buffer, ref uint modes, IntPtr modeBuffer);
        internal static ConfigPath[] QueryPaths(PathSizes sizes, PathQuery query)
        {
            for (int attempt = 0; attempt < Policy.RetryLimit; attempt++)
            {
                uint paths, modes;
                int status = sizes(out paths, out modes);
                if (status != 0) throw new Win32Exception(status, "Sizing display configuration failed.");
                if (paths > Policy.MaxItems || modes > Policy.MaxItems * 4) throw new InvalidDataException("Display configuration exceeds its size limit.");
                ConfigPath[] buffer = new ConfigPath[paths];
                IntPtr modeBuffer = modes == 0 ? IntPtr.Zero : Marshal.AllocHGlobal(checked((int)modes * 64));
                try
                {
                    uint pathCapacity = paths, modeCapacity = modes;
                    status = query(ref paths, buffer, ref modes, modeBuffer);
                    if (status == 122) continue;
                    if (status != 0) throw new Win32Exception(status, "Reading display configuration failed.");
                    if (paths > pathCapacity || modes > modeCapacity) throw new InvalidDataException("Display configuration returned invalid counts.");
                    Array.Resize(ref buffer, (int)paths);
                    return buffer;
                }
                finally { if (modeBuffer != IntPtr.Zero) Marshal.FreeHGlobal(modeBuffer); }
            }
            throw new InvalidOperationException("Display topology kept changing; retry limit reached.");
        }
        public DisplayRecord[] ReadDisplays()
        {
            const uint flags = 0x11; // QDC_ALL_PATHS | QDC_VIRTUAL_MODE_AWARE
            ConfigPath[] paths = QueryPaths(delegate(out uint p, out uint m) { return Api.GetDisplayConfigBufferSizes(flags, out p, out m); },
                delegate(ref uint p, ConfigPath[] b, ref uint m, IntPtr mb) { return Api.QueryDisplayConfig(flags, ref p, b, ref m, mb, IntPtr.Zero); });
            List<DisplayRecord> result = new List<DisplayRecord>();
            foreach (ConfigPath path in paths)
            {
                if (path.Target.Available == 0) continue;
                TargetName target = new TargetName { Header = new InfoHeader { Type = 2, Size = (uint)Marshal.SizeOf(typeof(TargetName)), Adapter = path.Target.Adapter, Id = path.Target.Id } };
                int status = Api.DisplayConfigGetTargetInfo(ref target);
                if (status != 0) throw new Win32Exception(status, "Reading the monitor path failed.");
                if (String.IsNullOrEmpty(target.Path)) continue;
                SourceName source = new SourceName { Header = new InfoHeader { Type = 1, Size = (uint)Marshal.SizeOf(typeof(SourceName)), Adapter = path.Source.Adapter, Id = path.Source.Id } };
                status = Api.DisplayConfigGetSourceInfo(ref source);
                bool active = (path.Flags & 1) != 0;
                if (status != 0 && active) throw new Win32Exception(status, "Reading the active display name failed.");
                result.Add(new DisplayRecord { Path = target.Path, Name = target.FriendlyName, DisplayName = status == 0 ? source.Name : "", Active = active });
            }
            return result.ToArray();
        }
    }

    [StructLayout(LayoutKind.Sequential)] internal struct DevInfo { internal uint Size; internal Guid ClassGuid; internal uint DevInst; internal UIntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential)] internal struct InterfaceData { internal uint Size; internal Guid ClassGuid; internal uint Flags; internal UIntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential)] internal struct PropertyKey { internal Guid Format; internal uint Id; }
    [StructLayout(LayoutKind.Sequential)] internal struct FileInformation
    {
        internal uint Attributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
        internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct InstallParameters
    {
        internal uint Size, Flags, FlagsEx;
        internal IntPtr Parent, Callback, Context, Queue;
        internal UIntPtr ClassReserved;
        internal uint Reserved;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] internal string DriverPath;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct DriverInfo
    {
        internal uint Size, Type;
        internal UIntPtr Reserved;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] internal string Description;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] internal string Manufacturer;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] internal string Provider;
        internal System.Runtime.InteropServices.ComTypes.FILETIME Date;
        internal ulong Version;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct Luid { internal uint Low; internal int High; }
    [StructLayout(LayoutKind.Sequential)] internal struct Rational { internal uint Numerator, Denominator; }
    [StructLayout(LayoutKind.Sequential)] internal struct PathSource { internal Luid Adapter; internal uint Id, ModeIndex, StatusFlags; }
    [StructLayout(LayoutKind.Sequential)] internal struct PathTarget
    {
        internal Luid Adapter; internal uint Id, ModeIndex, Technology, Rotation, Scaling;
        internal Rational RefreshRate;
        internal uint Scanline, Available, StatusFlags;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct ConfigPath { internal PathSource Source; internal PathTarget Target; internal uint Flags; }
    [StructLayout(LayoutKind.Sequential)] internal struct InfoHeader { internal uint Type, Size; internal Luid Adapter; internal uint Id; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct TargetName
    {
        internal InfoHeader Header; internal uint Flags, Technology; internal ushort Manufacturer, Product;
        internal uint Connector;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] internal string FriendlyName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string Path;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct SourceName
    {
        internal InfoHeader Header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] internal string Name;
    }

    internal static class Api
    {
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupCopyOEMInfW(string source, string media, uint mediaType, uint flags, IntPtr destination, uint size, IntPtr required, IntPtr component);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern SafeFileHandle CreateFileW(string path, uint access, uint sharing, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation information);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr SetupDiGetClassDevsW(ref Guid guid, string enumerator, IntPtr parent, uint flags);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiEnumDeviceInfo(IntPtr set, uint index, ref DevInfo device);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiGetDeviceInstanceIdW(IntPtr set, ref DevInfo device, StringBuilder id, uint size, out uint required);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiGetDeviceRegistryPropertyW(IntPtr set, ref DevInfo device, uint property, out uint type, [Out] byte[] data, uint size, out uint required);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiGetDevicePropertyW(IntPtr set, ref DevInfo device, ref PropertyKey key, out uint type, [Out] byte[] data, uint size, out uint required, uint flags);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", SetLastError = true)] internal static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid guid, IntPtr parent);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiOpenDeviceInfoW(IntPtr set, string id, IntPtr parent, uint flags, ref DevInfo device);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiCreateDeviceInfoW(IntPtr set, string name, ref Guid guid, string description, IntPtr parent, uint flags, ref DevInfo device);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr set, ref DevInfo device, uint property, byte[] data, uint size);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiCallClassInstaller(uint function, IntPtr set, ref DevInfo device);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiGetDeviceInstallParamsW(IntPtr set, ref DevInfo device, ref InstallParameters parameters);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiSetDeviceInstallParamsW(IntPtr set, ref DevInfo device, ref InstallParameters parameters);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiBuildDriverInfoList(IntPtr set, ref DevInfo device, uint type);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiDestroyDriverInfoList(IntPtr set, ref DevInfo device, uint type);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiEnumDriverInfoW(IntPtr set, ref DevInfo device, uint type, uint index, ref DriverInfo driver);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("newdev.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool DiInstallDevice(IntPtr parent, IntPtr set, ref DevInfo device, ref DriverInfo driver, uint flags, [MarshalAs(UnmanagedType.Bool)] out bool reboot);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("newdev.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool DiUninstallDevice(IntPtr parent, IntPtr set, ref DevInfo device, uint flags, [MarshalAs(UnmanagedType.Bool)] out bool reboot);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr device, ref Guid guid, uint index, ref InterfaceData data);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr set, ref InterfaceData data, IntPtr detail, uint size, out uint required, ref DevInfo device);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("cfgmgr32.dll")] internal static extern uint CM_Get_Parent(out uint parent, uint child, uint flags);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] internal static extern uint CM_Get_Device_IDW(uint device, StringBuilder id, uint length, uint flags);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("user32.dll")] internal static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("user32.dll")] internal static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] ConfigPath[] buffer, ref uint modes, IntPtr modeBuffer, IntPtr topology);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo", CharSet = CharSet.Unicode)] internal static extern int DisplayConfigGetTargetInfo(ref TargetName target);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo", CharSet = CharSet.Unicode)] internal static extern int DisplayConfigGetSourceInfo(ref SourceName source);
    }
}
