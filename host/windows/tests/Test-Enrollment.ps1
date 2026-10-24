#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Actual client parser/certificate pin/framing, with MemoryStreams only. No GUI,
# service, network connection, existing identity, preferences or user data.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=[IO.File]::ReadAllText((Join-Path $root 'EnrollmentClient.cs'))
$checks=@'
namespace Knot.Enrollment {
 internal sealed class FragmentedMemory : System.IO.MemoryStream {
  public FragmentedMemory() : base() { }
  public override System.Threading.Tasks.Task<int> ReadAsync(byte[] buffer,int offset,int count,System.Threading.CancellationToken token) {
   return base.ReadAsync(buffer,offset,System.Math.Min(1,count),token);
  }
 }
 public static class SyntheticChecks {
  private static int count;
  private static void Expect(bool value) { if (!value) throw new System.Exception("enrollment fixture failed"); count++; }
  private static void Reject(System.Action action) { bool rejected=false; try { action(); } catch { rejected=true; } Expect(rejected); }
  public static int Run() {
   count=0;
   string id="11111111-1111-4111-8111-111111111111", pin=new string('a',64), token=new string('b',64);
   string good="knot-enroll://192.168.1.20:20000/"+id+"#"+pin+"."+token;
   var link=Link.Parse(good); Expect(link.Address=="192.168.1.20" && link.Port==20000 && link.SessionID==id);
   foreach (string bad in new string[]{good+"\n",good+"?x=1",good.Replace("20000","020000"),good.Replace("192.168.1.20","127.0.0.1"),good.Replace("192.168.1.20","8.8.8.8"),good.Replace("192.168.1.20","169.254.1.20"),good.Replace("knot-enroll","https"),good.Replace("192.168.1.20","user@192.168.1.20"),good.Replace("#","?x=#"),good.Replace(pin,new string('A',64)),good.Replace(id,"invalid"),new string('a',513)}) Reject(delegate { Link.Parse(bad); });
   foreach (string address in new string[]{"10.1.2.3","172.16.1.2","172.31.1.2","100.64.1.2","100.127.1.2"}) Expect(Link.Parse(good.Replace("192.168.1.20",address)).Address==address);
   foreach (string address in new string[]{"172.15.1.2","172.32.1.2","100.63.1.2","100.128.1.2","192.169.1.2"}) Reject(delegate { Link.Parse(good.Replace("192.168.1.20",address)); });
   foreach (string local in new string[]{"192.168.1.20","100.80.1.20"}) {
    var endpoint=new System.Net.IPEndPoint(System.Net.IPAddress.Parse(local),50000);
    Expect(Link.LocalAddressFromEndpoint(endpoint)==local);
    Expect(Client.SelectLocalAddress(local,new string[]{"192.168.1.20","100.80.1.20"})==local);
    Reject(delegate { Client.SelectLocalAddress(local,new string[]{"10.0.0.1"}); });
   }
   foreach (string local in new string[]{"127.0.0.1","8.8.8.8","169.254.1.20","::1"}) {
    Reject(delegate { Link.LocalAddressFromEndpoint(new System.Net.IPEndPoint(System.Net.IPAddress.Parse(local),50000)); });
    Reject(delegate { Client.SelectLocalAddress(local,new string[]{local}); });
   }
   Reject(delegate { Link.LocalAddressFromEndpoint(null); });
   Reject(delegate { Link.LocalAddressFromEndpoint(new System.Net.DnsEndPoint("synthetic.invalid",50000)); });
   Reject(delegate { Client.SelectLocalAddress("192.168.001.20",new string[]{"192.168.001.20"}); });
   byte[] certificate=System.Text.Encoding.UTF8.GetBytes("fresh inert bytes; not a real certificate");
   string expected; using (var hash=System.Security.Cryptography.SHA256.Create()) expected=System.BitConverter.ToString(hash.ComputeHash(certificate)).Replace("-","").ToLowerInvariant();
   Expect(Link.MatchesPin(certificate,expected)); Expect(!Link.MatchesPin(certificate,pin)); Expect(!Link.MatchesPin(null,expected)); Expect(!Link.MatchesPin(certificate,""));
   foreach (int size in new int[]{1,2,16384}) {
    byte[] bytes=new byte[size]; for (int i=0;i<size;i++) bytes[i]=(byte)(i%256);
    using (var stream=new FragmentedMemory()) {
     Frames.WriteAsync(stream,bytes,System.Threading.CancellationToken.None).GetAwaiter().GetResult();
     Expect(stream.Length==size+4); stream.Position=0;
     var result=Frames.ReadAsync(stream,System.Threading.CancellationToken.None).GetAwaiter().GetResult();
     Expect(result.Length==size); for (int i=0;i<size;i++) if (result[i]!=bytes[i]) throw new System.Exception("frame bytes changed");
    }
   }
   foreach (byte[] bad in new byte[][]{new byte[0],new byte[]{0},new byte[]{0,0,0,0},new byte[]{0,0,64,1},new byte[]{255,255,255,255},new byte[]{0,0,0,2,1}}) {
    using (var stream=new System.IO.MemoryStream(bad)) Reject(delegate { Frames.ReadAsync(stream,System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
   }
   using (var stream=new System.IO.MemoryStream()) {
    Reject(delegate { Frames.WriteAsync(stream,new byte[0],System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
    Reject(delegate { Frames.WriteAsync(stream,new byte[16385],System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
    using (var cancel=new System.Threading.CancellationTokenSource()) { cancel.Cancel(); Reject(delegate { Frames.ReadAsync(stream,cancel.Token).GetAwaiter().GetResult(); }); }
   }
   return count;
  }
 }
}
'@
# Distinct namespace makes the actual client source and same-assembly helpers
# replayable even when another suite already loaded production types.
$namespace='Knot.Enrollment.Fixture'+[Guid]::NewGuid().ToString('N')
Add-Type -TypeDefinition (($source+"`n"+$checks).Replace('namespace Knot.Enrollment {',('namespace '+$namespace+' {')))
$type=($namespace+'.SyntheticChecks') -as [type]
$count=$type.GetMethod('Run').Invoke($null,@())
# Parse modified WinForms code without loading it or executing native leaves.
$tokens=$null; $errors=$null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Setup-DeskBridge.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Enrollment setup UI has PowerShell parse errors.' }
# The real broker rebuilds a public reply from the CURRENT request even when
# the existing, identical managed deployment is reused. Execute only that
# hashtable AST with inert public variables, never the broker or Resume script.
Import-Module (Join-Path $root 'SetupContract.psm1') -Force
$brokerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-DeskBridgeSetup.ps1'),[ref]$tokens,[ref]$errors)
$assign=@($brokerAst.FindAll({param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'reply'
},$true))
if ($errors.Count -or $assign.Count -ne 1 -or @($assign[0].Right.FindAll({param($node) $node -is [Management.Automation.Language.HashtableAst]},$true)).Count -ne 1) { throw 'Broker reply fixture extraction failed.' }
if ((Get-ManagedDeploymentAction $true $true $true $true $true $true $true) -cne 'Reuse') { throw 'Matching setup retry did not reuse deployment.' }
$prefix=[byte[]](0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32)
$clientKey='ssh-ed25519 '+[Convert]::ToBase64String([byte[]]($prefix+(@(1)*32)))
$key='ssh-ed25519 '+[Convert]::ToBase64String([byte[]]($prefix+(@(2)*32)))
$address='192.168.1.30'; $previousID=$null
foreach ($id in @('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222')) {
    $request=ConvertFrom-MacSetup (@{kind='deskbridge.mac-setup';version=1;requestID=$id;clientPublicKey=$clientKey;allowedClientAddresses=@('192.168.1.20')} | ConvertTo-Json -Compress)
    $reply=& ([scriptblock]::Create($assign[0].Right.Extent.Text))
    if ($reply.requestID -cne $id -or $reply.requestID -ceq $previousID -or $reply.clientPublicKey -cne $clientKey -or $reply.address -cne $address -or $reply.serverPublicKey -cne $key) { throw 'Reused setup returned stale public enrollment identity.' }
    $previousID=$reply.requestID; $count++
}
@{status='passed';checks=$count+3;freshSyntheticOnly=$true;network=$false;ui=$false;services=$false;actualBrokerReplyProjection=$true} | ConvertTo-Json -Compress
