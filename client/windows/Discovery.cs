// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DeskBridge.Reverse
{
    public sealed class ReverseCandidate
    {
        public string Name { get; private set; }
        public string Address { get; private set; }
        internal ReverseCandidate(string name, string address) { Name = name; Address = address; }
        public override string ToString() { return Name + " · " + Address; }
    }

    // Discovery gathers untrusted DNS-SD hints. It never probes a host or grants pairing.
    public static class ReverseDiscovery
    {
        internal static readonly string[] Services = { "_nvstream._tcp.local", "_nvstream-tcp._tcp.local" };
        public static Task<IList<ReverseCandidate>> FindAsync(CancellationToken cancel)
        { return Task.Run<IList<ReverseCandidate>>(() => Find(cancel), cancel); }

        private static IList<ReverseCandidate> Find(CancellationToken cancel)
        {
            var cache = new DiscoveryCache();
            var clock = Stopwatch.StartNew();
            using (var udp = new UdpClient(AddressFamily.InterNetwork))
            {
                udp.Client.Bind(new IPEndPoint(IPAddress.Any, 0));
                udp.Client.ReceiveTimeout = 200;
                udp.Client.ReceiveBufferSize = 65536;
                udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 255);
                int nextQuery = 0, packets = 0;
                while (clock.ElapsedMilliseconds < 8000 && packets < 256)
                {
                    cancel.ThrowIfCancellationRequested();
                    if (clock.ElapsedMilliseconds >= nextQuery)
                    {
                        SendQueries(udp, cancel);
                        nextQuery += 3000;
                    }
                    try
                    {
                        IPEndPoint sender = null;
                        byte[] packet = udp.Receive(ref sender);
                        packets++;
                        if (sender == null || sender.Port != 5353 || !SuggestedAddress(sender.Address.ToString())) continue;
                        cache.Accept(packet, (int)clock.ElapsedMilliseconds);
                    }
                    catch (SocketException error)
                    {
                        if (error.SocketErrorCode != SocketError.TimedOut && error.SocketErrorCode != SocketError.WouldBlock)
                            throw new ReverseUserException(ReverseFailure.Discovery);
                    }
                }
                cancel.ThrowIfCancellationRequested();
                return cache.Candidates((int)clock.ElapsedMilliseconds);
            }
        }

        private static void SendQueries(UdpClient udp, CancellationToken cancel)
        {
            var addresses = new HashSet<string>(StringComparer.Ordinal);
            foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                cancel.ThrowIfCancellationRequested();
                if (nic.OperationalStatus != OperationalStatus.Up || !nic.SupportsMulticast || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                foreach (UnicastIPAddressInformation item in nic.GetIPProperties().UnicastAddresses)
                {
                    if (item.Address.AddressFamily == AddressFamily.InterNetwork && SuggestedAddress(item.Address.ToString()) && !item.Address.ToString().StartsWith("100.", StringComparison.Ordinal))
                        addresses.Add(item.Address.ToString());
                    if (addresses.Count >= 16) break;
                }
                if (addresses.Count >= 16) break;
            }
            foreach (string address in addresses)
            {
                cancel.ThrowIfCancellationRequested();
                try
                {
                    udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, IPAddress.Parse(address).GetAddressBytes());
                    foreach (string service in Services)
                    {
                        byte[] query = Query(service);
                        udp.Send(query, query.Length, new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353));
                    }
                }
                catch (SocketException) { /* A disappearing interface does not authorize other probes. */ }
            }
        }

        internal static bool SuggestedAddress(string value)
        {
            try { return ConnectionPolicy.Address(value) == value && !value.StartsWith("169.254.", StringComparison.Ordinal); }
            catch (FormatException) { return false; }
        }
        internal static byte[] Query(string service)
        {
            if (!Services.Contains(service, StringComparer.Ordinal)) throw new ArgumentException("service");
            var data = new List<byte>(new byte[] { 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 });
            foreach (string label in service.Split('.')) { byte[] bytes = Encoding.ASCII.GetBytes(label); data.Add((byte)bytes.Length); data.AddRange(bytes); }
            data.AddRange(new byte[] { 0, 0, 12, 128, 1 }); // PTR / IN, request unicast replies to our ephemeral port.
            return data.ToArray();
        }
    }

    internal sealed class DiscoveryRecord
    {
        internal string Owner, Target, Address;
        internal int Type, Port, Expires;
        internal uint Ttl;
    }

    internal sealed class DiscoveryCache
    {
        private readonly Dictionary<string, DiscoveryRecord> pointers = new Dictionary<string, DiscoveryRecord>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, DiscoveryRecord> servers = new Dictionary<string, DiscoveryRecord>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, DiscoveryRecord> addresses = new Dictionary<string, DiscoveryRecord>(StringComparer.OrdinalIgnoreCase);
        internal bool Accept(byte[] packet, int now)
        {
            IList<DiscoveryRecord> records = DiscoveryPacket.Read(packet);
            if (records == null || now < 0 || now > 60000) return false;
            Expire(pointers, now); Expire(servers, now); Expire(addresses, now);
            foreach (DiscoveryRecord record in records)
            {
                record.Expires = now + (int)Math.Min(record.Ttl, 300U) * 1000;
                if (record.Type == 12 && ReverseDiscovery.Services.Contains(record.Owner, StringComparer.OrdinalIgnoreCase))
                    Put(pointers, record.Target, record, 64);
                else if (record.Type == 33) Put(servers, record.Owner, record, 64);
                else if (record.Type == 1 && ReverseDiscovery.SuggestedAddress(record.Address)) Put(addresses, record.Owner + "|" + record.Address, record, 128);
            }
            return true;
        }
        private static void Expire(Dictionary<string, DiscoveryRecord> cache, int now)
        {
            foreach (string key in cache.Where(x => x.Value.Expires <= now).Select(x => x.Key).ToList()) cache.Remove(key);
        }
        private static void Put(Dictionary<string, DiscoveryRecord> cache, string key, DiscoveryRecord record, int maximum)
        {
            if (record.Ttl == 0) { cache.Remove(key); return; }
            if (cache.Count < maximum || cache.ContainsKey(key)) cache[key] = record;
        }
        internal IList<ReverseCandidate> Candidates(int now)
        {
            var result = new Dictionary<string, ReverseCandidate>(StringComparer.Ordinal);
            foreach (DiscoveryRecord pointer in pointers.Values)
            {
                if (pointer.Expires <= now || !pointer.Target.EndsWith("." + pointer.Owner, StringComparison.OrdinalIgnoreCase)) continue;
                DiscoveryRecord server;
                if (!servers.TryGetValue(pointer.Target, out server) || server.Expires <= now || server.Port != 47989) continue;
                string name = pointer.Target.Substring(0, pointer.Target.Length - pointer.Owner.Length - 1);
                if (!ConnectionPolicy.ValidName(name)) continue;
                foreach (DiscoveryRecord address in addresses.Values)
                {
                    if (address.Expires > now && String.Equals(address.Owner, server.Target, StringComparison.OrdinalIgnoreCase) && !result.ContainsKey(address.Address) && result.Count < 32)
                        result.Add(address.Address, new ReverseCandidate(name, address.Address));
                }
            }
            return result.Values.OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase).ThenBy(x => x.Address, StringComparer.Ordinal).ToList().AsReadOnly();
        }
    }

    internal static class DiscoveryPacket
    {
        internal static IList<DiscoveryRecord> Read(byte[] bytes)
        {
            if (bytes == null || bytes.Length < 12 || bytes.Length > 9000) return null;
            try
            {
                int position = 0;
                U16(bytes, ref position); int flags = U16(bytes, ref position);
                if ((flags & 0x8000) == 0 || (flags & 0x7a0f) != 0) return null; // response; no opcode, truncation, error.
                int questions = U16(bytes, ref position);
                int records = U16(bytes, ref position) + U16(bytes, ref position) + U16(bytes, ref position);
                if (questions > 16 || records > 96) return null;
                for (int i = 0; i < questions; i++) { Name(bytes, ref position); U16(bytes, ref position); U16(bytes, ref position); }
                var result = new List<DiscoveryRecord>();
                for (int i = 0; i < records; i++)
                {
                    string owner = Name(bytes, ref position);
                    int type = U16(bytes, ref position), klass = U16(bytes, ref position) & 0x7fff;
                    uint ttl = ((uint)U16(bytes, ref position) << 16) | (uint)U16(bytes, ref position);
                    int length = U16(bytes, ref position), end = position + length;
                    if (end > bytes.Length) throw new FormatException();
                    var record = new DiscoveryRecord { Owner = owner, Type = type, Ttl = ttl };
                    if (klass == 1 && type == 12)
                    { record.Target = Name(bytes, ref position); if (position != end) throw new FormatException(); result.Add(record); }
                    else if (klass == 1 && type == 33)
                    {
                        U16(bytes, ref position); U16(bytes, ref position); record.Port = U16(bytes, ref position);
                        record.Target = Name(bytes, ref position); if (position != end) throw new FormatException(); result.Add(record);
                    }
                    else if (klass == 1 && type == 1 && length == 4)
                    {
                        record.Address = String.Join(".", bytes.Skip(position).Take(4).Select(x => x.ToString(System.Globalization.CultureInfo.InvariantCulture)));
                        result.Add(record);
                    }
                    position = end;
                }
                return position == bytes.Length ? result : null;
            }
            catch (FormatException) { return null; }
            catch (DecoderFallbackException) { return null; }
        }
        private static int U16(byte[] bytes, ref int position)
        {
            if (position < 0 || position > bytes.Length - 2) throw new FormatException();
            int value = (bytes[position] << 8) | bytes[position + 1]; position += 2; return value;
        }
        private static string Name(byte[] bytes, ref int position)
        {
            int cursor = position, expanded = 0, next = -1, jumps = 0;
            var labels = new List<string>();
            while (true)
            {
                if (cursor < 0 || cursor >= bytes.Length) throw new FormatException();
                int start = cursor, length = bytes[cursor++];
                if ((length & 0xc0) == 0xc0)
                {
                    if (cursor >= bytes.Length || ++jumps > 16) throw new FormatException();
                    int target = ((length & 63) << 8) | bytes[cursor++];
                    if (target >= start || target < 12) throw new FormatException();
                    if (next < 0) next = cursor;
                    cursor = target;
                    continue;
                }
                if (length > 63 || cursor > bytes.Length - length || (expanded += length + 1) > 255) throw new FormatException();
                if (length == 0) { position = next < 0 ? cursor : next; return String.Join(".", labels); }
                string label = new UTF8Encoding(false, true).GetString(bytes, cursor, length);
                if (label.Any(c => Char.IsControl(c))) throw new FormatException();
                labels.Add(label); cursor += length;
            }
        }
    }
}
