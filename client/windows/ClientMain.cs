// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Windows.Forms;

namespace DeskBridge.Reverse
{
    public static class ClientMain
    {
        [STAThread]
        public static int Main(string[] args)
        {
            try
            {
                if (args == null || args.Length != 2 || args[0] != "--bootstrap-path")
                    throw new ReverseUserException(ReverseFailure.BootstrapRequired);
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using (var image = new FileStream(Assembly.GetExecutingAssembly().Location, FileMode.Open, FileAccess.Read, FileShare.Read))
                    RunEmbedded(args[1]);
                return 0;
            }
            catch (Exception error)
            {
                MessageBox.Show(ReverseErrors.ForOperation(error), "Knot · Mac 열기", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 2;
            }
        }

        // Existing native bootstrap/Launcher own original image locks and extraction. No elevation or broker exists here.
        public static void RunEmbedded(string originalBootstrapPath)
        { RunEmbedded(originalBootstrapPath, HostPlatform.Mac); }

        public static void RunEmbedded(string originalBootstrapPath, HostPlatform platform)
        {
            try { RunCore(originalBootstrapPath, platform); }
            catch (ReverseUserException) { throw; }
            catch (Exception) { throw new ReverseUserException(ReverseFailure.OperationFailed); }
        }

        private static void RunCore(string originalBootstrapPath, HostPlatform platform)
        {
            ValidateBootstrap(originalBootstrapPath);
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                if (new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
                    throw new ReverseUserException(ReverseFailure.AdministratorNotAllowed);
            ushort processMachine, nativeMachine;
            if (!Environment.Is64BitProcess || !IsWow64Process2(Process.GetCurrentProcess().Handle, out processMachine, out nativeMachine) ||
                nativeMachine != 0x8664 || Environment.OSVersion.Version.Build < 22000)
                throw new ReverseUserException(ReverseFailure.WindowsRequired);
            if (platform != HostPlatform.Mac && platform != HostPlatform.Linux) throw new ReverseUserException(ReverseFailure.OperationFailed);
            using (var form = new ClientForm(platform)) Application.Run(form);
        }

        internal static void ValidateBootstrap(string path)
        {
            if (String.IsNullOrWhiteSpace(path) || path.Length > 32700 || path.IndexOf('\0') >= 0 || !Path.IsPathRooted(path) ||
                !String.Equals(Path.GetFullPath(path), path, StringComparison.OrdinalIgnoreCase) ||
                !path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || !File.Exists(path))
                throw new ReverseUserException(ReverseFailure.BootstrapRequired);
            PrivateFiles.OrdinaryAncestors(path);
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
    }
}
