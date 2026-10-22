// SPDX-License-Identifier: GPL-3.0-only
// Compiled with the actual SetupDownload module source; all responses are synthetic streams.
namespace DeskBridge.Setup
{
    public static class SetupDownloadChecks
    {
        private static int checks;
        private static void Check(bool ok, string label) { checks++; if (!ok) throw new Exception("FAIL " + label); }
        private sealed class SyntheticStream : MemoryStream
        {
            internal bool Closed;
            internal int DelayMs, Chunk = 3;
            internal SyntheticStream(int size) : base(new byte[size]) { }
            public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancel)
            {
                if (DelayMs != 0) await Task.Delay(DelayMs, cancel).ConfigureAwait(false);
                cancel.ThrowIfCancellationRequested();
                return Read(buffer, offset, Math.Min(count, Chunk));
            }
            protected override void Dispose(bool disposing) { Closed = true; base.Dispose(disposing); }
        }
        private static DownloadResponse Response(SyntheticStream stream, long length)
        { return new DownloadResponse { Status = 200, Length = length, Body = stream }; }
        private static async Task Reject(Func<Task> operation, string path, string label, string message = null)
        {
            bool failed = false;
            try { await operation().ConfigureAwait(false); }
            catch (Exception error) { failed = message == null || error.Message.Contains(message); }
            Check(failed, label); Check(!File.Exists(path), label + " partial removed");
        }
        public static int Run(string directory) { RunAsync(directory).GetAwaiter().GetResult(); return checks; }
        private static async Task RunAsync(string directory)
        {
            checks = 0;
            var uri = new Uri("https://github.com/synthetic-fixture");
            string path = Path.Combine(directory, "bounded.bin");
            foreach (string value in new[] { "http://github.com/x", "https://github.com.evil.test/x", "https://user@github.com/x", "https://github.com:444/x", "https://github.com/x#fragment", "https://127.0.0.1/x" })
                Check(!BoundedDownload.SafeUri(new Uri(value)), "redirect rejected");
            foreach (string host in new[] { "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com" })
                Check(BoundedDownload.SafeUri(new Uri("https://" + host + "/x")), "official redirect accepted");
            var body = new SyntheticStream(7); long progress = 0; int opens = 0;
            await BoundedDownload.FetchAsync(uri, path, 7, CancellationToken.None, bytes => progress = bytes,
                (url, token) => { opens++; return Task.FromResult(Response(body, -1)); }, 1000, 5000);
            Check(File.ReadAllBytes(path).Length == 7 && progress == 7 && body.Closed && opens == 1, "exact chunked body closes and succeeds");
            File.Delete(path);
            body = new SyntheticStream(9); progress = 0;
            await Reject(() => BoundedDownload.FetchAsync(uri, path, 4, CancellationToken.None, bytes => progress = bytes,
                (url, token) => Task.FromResult(Response(body, -1)), 1000, 5000), path, "overflow");
            Check(progress == 3 && body.Closed, "overflow chunk never written and response closed");
            body = new SyntheticStream(3);
            await Reject(() => BoundedDownload.FetchAsync(uri, path, 4, CancellationToken.None, bytes => { },
                (url, token) => Task.FromResult(Response(body, -1)), 1000, 5000), path, "truncation");
            Check(body.Closed, "truncated stream closed");
            body = new SyntheticStream(8);
            await Reject(() => BoundedDownload.FetchAsync(uri, path, 4, CancellationToken.None, bytes => { },
                (url, token) => Task.FromResult(Response(body, 8)), 1000, 5000), path, "declared oversized body");
            Check(body.Closed, "header rejection closes response");
            body = new SyntheticStream(4) { DelayMs = -1 };
            await Reject(() => BoundedDownload.FetchAsync(uri, path, 4, CancellationToken.None, bytes => { },
                (url, token) => Task.FromResult(Response(body, -1)), 40, 2000), path, "idle timeout", "60초");
            Check(body.Closed, "idle closes response");
            await Reject(() => BoundedDownload.FetchAsync(uri, path, 4, CancellationToken.None, bytes => { },
                async (url, token) => { await Task.Delay(-1, token); return Response(new SyntheticStream(4), 4); }, 40, 2000), path, "header idle timeout", "60초");
            body = new SyntheticStream(1000) { DelayMs = 15, Chunk = 1 }; progress = 0;
            await Reject(() => BoundedDownload.FetchAsync(uri, path, 1000, CancellationToken.None, bytes => progress = bytes,
                (url, token) => Task.FromResult(Response(body, -1)), 1000, 400), path, "drip absolute deadline", "10분");
            Check(progress > 0 && progress < 1000 && body.Closed, "drip made progress but absolute deadline won");
            body = new SyntheticStream(4) { DelayMs = -1 };
            using (var cancel = new CancellationTokenSource())
            {
                cancel.CancelAfter(40);
                bool cancelled = false;
                try { await BoundedDownload.FetchAsync(uri, path, 4, cancel.Token, bytes => { }, (url, token) => Task.FromResult(Response(body, -1)), 2000, 5000); }
                catch (OperationCanceledException) { cancelled = true; }
                Check(cancelled && body.Closed && !File.Exists(path), "user cancellation closes and removes partial");
            }
            opens = 0;
            await Reject(() => BoundedDownload.FetchAsync(uri, path, 4, CancellationToken.None, bytes => { },
                (url, token) => { opens++; return Task.FromResult(new DownloadResponse { Status = 302, Location = "https://evil.test/no" }); }, 1000, 5000), path, "foreign redirect");
            Check(opens == 1, "foreign redirect is rejected before opening");
            opens = 0;
            await Reject(() => BoundedDownload.FetchAsync(uri, path, 4, CancellationToken.None, bytes => { },
                (url, token) => { opens++; return Task.FromResult(new DownloadResponse { Status = 307, Location = "/again" }); }, 1000, 5000), path, "redirect limit");
            Check(opens == 6, "redirect count bounded");
            opens = 0; body = new SyntheticStream(4);
            await BoundedDownload.FetchAsync(uri, path, 4, CancellationToken.None, bytes => { },
                (url, token) => Task.FromResult(++opens == 1 ? new DownloadResponse { Status = 302, Location = "https://release-assets.githubusercontent.com/synthetic" } : Response(body, 4)), 1000, 5000);
            Check(opens == 2 && body.Closed && File.Exists(path), "allowed redirect finishes");
            File.Delete(path);
            File.WriteAllText(path, "foreign synthetic file"); body = new SyntheticStream(4); bool collision = false;
            try { await BoundedDownload.FetchAsync(uri, path, 4, CancellationToken.None, bytes => { }, (url, token) => Task.FromResult(Response(body, 4)), 1000, 5000); }
            catch (IOException) { collision = true; }
            Check(collision && body.Closed && File.ReadAllText(path) == "foreign synthetic file", "never deletes or overwrites preexisting destination");
            File.Delete(path);
        }
    }
}
