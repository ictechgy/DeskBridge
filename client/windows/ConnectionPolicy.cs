// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace DeskBridge.Reverse
{
    public enum HostPlatform { Mac, Linux, Windows }

    public sealed class ReverseInvitation
    {
        public HostPlatform? Platform { get; private set; }
        public string Name { get; private set; }
        public IList<string> Addresses { get; private set; }
        internal ReverseInvitation(string name, List<string> addresses, HostPlatform? platform)
        { Name = name; Addresses = addresses.AsReadOnly(); Platform = platform; }
    }

    // Discovery, QR and manual addresses are hints. No result grants trust or initiates pairing.
    public static class ConnectionPolicy
    {
        public const int MaximumInvitationBytes = 1536;
        public static string Address(string input)
        {
            if (input == null) throw new FormatException("LAN 또는 Tailscale IPv4 주소를 입력하세요.");
            string value = input.Trim();
            string[] parts = value.Split('.');
            byte[] bytes = new byte[4];
            if (parts.Length != 4) throw BadAddress();
            for (int i = 0; i != 4; ++i)
            {
                if (parts[i].Length == 0 || parts[i].Length > 3 || (parts[i].Length > 1 && parts[i][0] == '0')) throw BadAddress();
                foreach (char c in parts[i]) if (c < '0' || c > '9') throw BadAddress();
                if (!Byte.TryParse(parts[i], NumberStyles.None, CultureInfo.InvariantCulture, out bytes[i])) throw BadAddress();
            }
            int a = bytes[0], b = bytes[1];
            if (!(a == 10 || a == 172 && b >= 16 && b <= 31 || a == 192 && b == 168 ||
                  a == 100 && b >= 64 && b <= 127 || a == 169 && b == 254)) throw BadAddress();
            return value;
        }

        public static bool ValidName(string name)
        {
            if (String.IsNullOrEmpty(name) || name.Length > 64 || Encoding.UTF8.GetByteCount(name) > 128 || name != name.Trim()) return false;
            for (int i = 0; i < name.Length; i++)
            {
                UnicodeCategory category = CharUnicodeInfo.GetUnicodeCategory(name, i);
                if (category == UnicodeCategory.Control || category == UnicodeCategory.Format || category == UnicodeCategory.Surrogate) return false;
                if (Char.IsHighSurrogate(name[i])) i++;
            }
            return true;
        }

        public static ReverseInvitation Parse(string input)
        {
            if (input == null) throw BadInvitation();
            string value = input.Trim();
            if (value.Length == 0 || Encoding.UTF8.GetByteCount(value) > MaximumInvitationBytes) throw BadInvitation();
            foreach (char c in value) if (Char.IsWhiteSpace(c) || Char.IsControl(c)) throw BadInvitation();
            // Parse the raw authority before URI normalization can hide escapes or credentials.
            const string prefix = "deskbridge://connect";
            if (!value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw BadInvitation();
            string tail = value.Substring(prefix.Length);
            if (tail.StartsWith("/", StringComparison.Ordinal)) tail = tail.Substring(1);
            if (!tail.StartsWith("?", StringComparison.Ordinal) || tail.IndexOf('#') >= 0) throw BadInvitation();
            string[] fields = tail.Substring(1).Split('&');
            if (fields.Length < 3 || fields.Length > 11) throw BadInvitation();
            string version = null, name = null, platformText = null;
            var addresses = new List<string>();
            foreach (string field in fields)
            {
                int equals = field.IndexOf('=');
                if (equals <= 0 || equals != field.LastIndexOf('=')) throw BadInvitation();
                string key = field.Substring(0, equals), item = Decode(field.Substring(equals + 1));
                if (key == "v" && version == null) version = item;
                else if (key == "name" && name == null) name = item;
                else if (key == "platform" && platformText == null) platformText = item;
                else if (key == "address")
                {
                    string address = Address(item);
                    if (address != item || addresses.Contains(address) || addresses.Count == 8) throw BadInvitation();
                    addresses.Add(address);
                }
                else throw BadInvitation();
            }
            HostPlatform? platform = null;
            if (version == "1" && platformText == null && fields.Length <= 10) { }
            else if (version == "2" && platformText != null)
            {
                if (platformText == "linux") platform = HostPlatform.Linux;
                else if (platformText == "macos") platform = HostPlatform.Mac;
                else if (platformText == "windows") platform = HostPlatform.Windows;
                else throw BadInvitation();
            }
            else throw BadInvitation();
            if (!ValidName(name) || addresses.Count == 0) throw BadInvitation();
            return new ReverseInvitation(name, addresses, platform);
        }

        public static void RequireRole(ReverseInvitation invitation, HostPlatform platform)
        {
            if (invitation == null || !(invitation.Platform == platform || invitation.Platform == null && platform == HostPlatform.Mac))
                throw new FormatException("연결 QR의 대상 OS가 다릅니다. 해당 PC의 역할을 선택하고 새 QR/링크를 가져오세요.");
        }
        public static bool MacCommandAllowed(HostPlatform platform, bool fullscreen, bool requested)
        { return platform == HostPlatform.Mac && fullscreen && requested; }

        private static string Decode(string value)
        {
            // URI query uses percent escaping, not form '+' decoding. Strict UTF-8 rejects smuggled bytes.
            var bytes = new List<byte>();
            for (int i = 0; i < value.Length;)
            {
                if (value[i] == '%')
                {
                    byte item;
                    if (i + 2 >= value.Length || !Byte.TryParse(value.Substring(i + 1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out item)) throw BadInvitation();
                    bytes.Add(item); i += 3;
                }
                else
                {
                    int length = Char.IsHighSurrogate(value[i]) && i + 1 < value.Length && Char.IsLowSurrogate(value[i + 1]) ? 2 : 1;
                    try { bytes.AddRange(new UTF8Encoding(false, true).GetBytes(value.Substring(i, length))); }
                    catch (EncoderFallbackException) { throw BadInvitation(); }
                    i += length;
                }
            }
            try { return new UTF8Encoding(false, true).GetString(bytes.ToArray()); }
            catch (DecoderFallbackException) { throw BadInvitation(); }
        }
        private static FormatException BadAddress() { return new FormatException("LAN 또는 Tailscale의 IPv4 주소만 지원합니다. 예: 192.168.1.20"); }
        private static FormatException BadInvitation() { return new FormatException("지원되는 PC 연결 링크가 아닙니다. 공유할 PC의 Knot에서 새 QR/링크를 만드세요."); }
    }
}
