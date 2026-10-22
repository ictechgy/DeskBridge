// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace DeskBridge.Reverse
{
    internal static class PrivateFiles
    {
        internal const string MarkerText = "DeskBridge reverse client data v1\n";
        internal static string OpenRoot()
        {
            string parent = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            OrdinaryAncestors(parent);
            string root = Path.Combine(parent, "DeskBridge-Reverse-v1");
            if (!Directory.Exists(root))
            {
                CreatePrivate(root);
                WriteNew(Path.Combine(root, "owner.txt"), MarkerText);
            }
            AssertPrivate(root);
            string marker = Path.Combine(root, "owner.txt");
            OrdinaryAncestors(marker);
            if (!File.Exists(marker) || new FileInfo(marker).Length != Encoding.UTF8.GetByteCount(MarkerText) || File.ReadAllText(marker) != MarkerText)
                throw new ReverseUserException(ReverseFailure.StoragePolicy);
            return root;
        }

        internal static void CreatePrivate(string path)
        {
            OrdinaryAncestors(Path.GetDirectoryName(path));
            if (Directory.Exists(path) || File.Exists(path)) throw new ReverseUserException(ReverseFailure.StoragePolicy);
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                var acl = new DirectorySecurity();
                acl.SetOwner(identity.User);
                acl.SetAccessRuleProtection(true, false);
                foreach (SecurityIdentifier sid in AllowedSids(identity.User))
                    acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                        InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                Directory.CreateDirectory(path, acl);
            }
            AssertPrivate(path);
        }

        internal static void AssertPrivate(string path)
        {
            OrdinaryAncestors(path);
            var acl = Directory.GetAccessControl(path, AccessControlSections.Access | AccessControlSections.Owner);
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                if (!identity.User.Equals(acl.GetOwner(typeof(SecurityIdentifier))) || !acl.AreAccessRulesProtected)
                    throw new ReverseUserException(ReverseFailure.StoragePolicy);
                var allowed = AllowedSids(identity.User);
                foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
                    if (rule.AccessControlType == AccessControlType.Allow && !allowed.Contains((SecurityIdentifier)rule.IdentityReference))
                        throw new ReverseUserException(ReverseFailure.StoragePolicy);
            }
        }

        internal static void OrdinaryAncestors(string path)
        {
            string current = Path.GetFullPath(path);
            while (!String.IsNullOrEmpty(current))
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new ReverseUserException(ReverseFailure.LinkedStorage);
                string next = Path.GetDirectoryName(current);
                if (next == current) break;
                current = next;
            }
        }

        internal static void WriteNew(string path, string text)
        {
            byte[] bytes = new UTF8Encoding(false, true).GetBytes(text);
            using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { file.Write(bytes, 0, bytes.Length); file.Flush(true); }
        }

        // Only paths recorded during our own fresh staging operation are eligible for deletion.
        internal static void CleanupCreated(IList<string> files, IList<string> directories)
        {
            for (int i = files.Count - 1; i >= 0; i--)
                try { OrdinaryAncestors(files[i]); File.Delete(files[i]); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            for (int i = directories.Count - 1; i >= 0; i--)
                try { OrdinaryAncestors(directories[i]); Directory.Delete(directories[i], false); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }

        private static List<SecurityIdentifier> AllowedSids(SecurityIdentifier user)
        {
            return new List<SecurityIdentifier> { user,
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) };
        }
    }
}
