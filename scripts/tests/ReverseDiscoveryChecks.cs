// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Text;
using DeskBridge.Reverse;

internal static class ReverseDiscoveryChecks
{
    private static int count;
    private static void Require(bool condition, string label)
    { if (!condition) throw new Exception("mDNS check: " + label); count++; }
    private static byte[] Name(string name)
    {
        var bytes = new List<byte>();
        foreach (string part in name.Split('.')) { byte[] label = Encoding.UTF8.GetBytes(part); bytes.Add((byte)label.Length); bytes.AddRange(label); }
        bytes.Add(0); return bytes.ToArray();
    }
    private static void U16(List<byte> data, int value) { data.Add((byte)(value >> 8)); data.Add((byte)value); }
    private static byte[] Record(string owner, int type, byte[] body, int ttl = 120, int klass = 1)
    {
        var bytes = new List<byte>(Name(owner)); U16(bytes, type); U16(bytes, klass);
        U16(bytes, ttl >> 16); U16(bytes, ttl); U16(bytes, body.Length); bytes.AddRange(body); return bytes.ToArray();
    }
    private static byte[] Packet(params byte[][] records)
    {
        var bytes = new List<byte>(new byte[] { 0, 0, 0x84, 0, 0, 0 });
        U16(bytes, records.Length); U16(bytes, 0); U16(bytes, 0);
        foreach (byte[] record in records) bytes.AddRange(record);
        return bytes.ToArray();
    }
    private static byte[] Server(string instance, string host, int port = 47989, int ttl = 120)
    {
        var data = new List<byte>(); U16(data, 0); U16(data, 0); U16(data, port); data.AddRange(Name(host));
        return Record(instance, 33, data.ToArray(), ttl);
    }
    private static byte[][] Valid(string ip = "192.168.1.20", int port = 47989, int ttl = 120)
    {
        var address = new List<byte>(); foreach (string part in ip.Split('.')) address.Add(Byte.Parse(part));
        return new[] { Record("_nvstream._tcp.local", 12, Name("개발 Mac._nvstream._tcp.local"), ttl),
            Server("개발 Mac._nvstream._tcp.local", "host.local", port, ttl), Record("host.local", 1, address.ToArray(), ttl) };
    }
    internal static int Run()
    {
        Require(ReverseDiscovery.Query("_nvstream._tcp.local").Length == 38, "PTR query with unicast response flag");
        Require(DiscoveryPacket.Read(null) == null, "null");
        Require(DiscoveryPacket.Read(new byte[11]) == null, "short header");
        Require(DiscoveryPacket.Read(new byte[9001]) == null, "packet bound");
        var cache = new DiscoveryCache();
        Require(cache.Accept(Packet(Valid()), 0), "valid response");
        Require(cache.Candidates(1).Count == 1 && cache.Candidates(1)[0].Name == "개발 Mac" && cache.Candidates(1)[0].Address == "192.168.1.20", "PTR SRV A chain");
        Require(cache.Candidates(120001).Count == 0, "TTL expires");
        foreach (string ip in new[] { "8.8.8.8", "127.0.0.1", "169.254.1.2", "0.0.0.0", "224.0.0.251" })
        {
            cache = new DiscoveryCache(); cache.Accept(Packet(Valid(ip)), 0); Require(cache.Candidates(1).Count == 0, "private suggestion: " + ip);
        }
        cache = new DiscoveryCache(); cache.Accept(Packet(Valid("100.88.1.2")), 0);
        Require(cache.Candidates(1).Count == 1, "private Tailscale hint accepted");
        cache = new DiscoveryCache(); cache.Accept(Packet(Valid("192.168.1.20", 444)), 0);
        Require(cache.Candidates(1).Count == 0, "no custom port");
        cache = new DiscoveryCache(); byte[][] records = Valid();
        cache.Accept(Packet(records[0]), 0); cache.Accept(Packet(records[1]), 0);
        Require(cache.Candidates(1).Count == 0, "no implicit address resolution");
        cache.Accept(Packet(records[2]), 1); Require(cache.Candidates(2).Count == 1, "additional records in later packet");
        cache.Accept(Packet(Valid("192.168.1.20", 47989, 0)), 3); Require(cache.Candidates(4).Count == 0, "goodbye removes hints");
        cache = new DiscoveryCache(); cache.Accept(Packet(Record("unrelated.local", 1, new byte[] { 10, 0, 0, 1 })), 0);
        Require(cache.Candidates(1).Count == 0, "unrelated A never candidate");
        byte[] broken = Packet(Valid()); broken[2] = 0;
        Require(DiscoveryPacket.Read(broken) == null, "query is not response");
        broken = Packet(Valid()); broken[2] |= 2; Require(DiscoveryPacket.Read(broken) == null, "truncated response");
        broken = Packet(Valid()); broken[3] |= 3; Require(DiscoveryPacket.Read(broken) == null, "DNS error");
        broken = Packet(Valid()); broken[4] = 1; Require(DiscoveryPacket.Read(broken) == null, "question cap");
        broken = Packet(Valid()); broken[6] = 1; Require(DiscoveryPacket.Read(broken) == null, "record cap");
        var trailing = new List<byte>(Packet(Valid())); trailing.Add(0); Require(DiscoveryPacket.Read(trailing.ToArray()) == null, "no trailing data");
        // A compressed owner points to the previous record's valid name at byte12.
        var compressed = new List<byte>(Packet(Record("host.local", 1, new byte[] { 10, 0, 0, 1 })));
        compressed[7] = 2;
        compressed.AddRange(new byte[] { 0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 120, 0, 4, 10, 0, 0, 2 });
        Require(DiscoveryPacket.Read(compressed.ToArray()).Count == 2, "valid compression");
        foreach (byte[] pointer in new[] { new byte[] { 0xc0, 12 }, new byte[] { 0xff, 0xff }, new byte[] { 0xc0, 0 }, new byte[] { 64, 0 } })
        {
            var invalid = new List<byte>(new byte[] { 0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0 }); invalid.AddRange(pointer);
            invalid.AddRange(new byte[] { 0, 1, 0, 1, 0, 0, 0, 120, 0, 4, 10, 0, 0, 1 });
            Require(DiscoveryPacket.Read(invalid.ToArray()) == null, "bad compression/label");
        }
        // Exhaustive truncations and deterministic bounded fuzz must not throw or leak partial hints.
        byte[] valid = Packet(Valid());
        for (int i = 0; i < valid.Length; i++) { var prefix = new byte[i]; Array.Copy(valid, prefix, i); Require(DiscoveryPacket.Read(prefix) == null, "truncated packet " + i); }
        var random = new Random(20261022);
        for (int i = 0; i < 3000; i++) { byte[] noise = new byte[random.Next(0, 512)]; random.NextBytes(noise); DiscoveryPacket.Read(noise); }
        Require(true, "3000 bounded fuzz packets");
        cache = new DiscoveryCache();
        for (int i = 1; i < 201; i++) cache.Accept(Packet(Record("_nvstream._tcp.local", 12, Name("Mac" + i + "._nvstream._tcp.local")), Server("Mac" + i + "._nvstream._tcp.local", "host" + i + ".local"), Record("host" + i + ".local", 1, new byte[] { 10, 0, 0, (byte)i })), 0);
        Require(cache.Candidates(1).Count == 32, "candidate bound");
        return count;
    }
}
