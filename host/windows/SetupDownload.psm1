#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# A worker owns every request/stream. The UI only observes progress and requests cancellation.
$source = @'
using System;
using System.IO;
using System.Net;
using System.Threading;
using System.Threading.Tasks;

namespace DeskBridge.Setup
{
    public sealed class DownloadOperation : IDisposable
    {
        private readonly CancellationTokenSource cancellation = new CancellationTokenSource();
        private long bytes;
        public long Bytes { get { return Interlocked.Read(ref bytes); } }
        public Task Completion { get; private set; }
        public DownloadOperation(string url, string path, long expectedBytes)
        {
            // Task.Run also moves response setup and file creation away from the WinForms thread.
            Completion = Task.Run(() => BoundedDownload.FetchAsync(new Uri(url), path, expectedBytes,
                cancellation.Token, count => Interlocked.Exchange(ref bytes, count),
                BoundedDownload.OpenAsync, 60000, 600000));
        }
        public void Cancel() { cancellation.Cancel(); }
        public void Dispose()
        {
            cancellation.Cancel();
            // The caller waits while pumping UI events before disposing; cleanup has then finished.
            if (!Completion.IsCompleted) throw new InvalidOperationException("Download is still stopping.");
            cancellation.Dispose();
        }
    }

    internal sealed class DownloadResponse : IDisposable
    {
        internal int Status;
        internal long Length;
        internal string Location;
        internal Stream Body;
        internal Action Abort = delegate { };
        internal Action Close = delegate { };
        public void Dispose() { try { if (Body != null) Body.Dispose(); } finally { Close(); } }
    }

    internal static class BoundedDownload
    {
        internal static bool SafeUri(Uri uri)
        {
            return uri != null && uri.IsAbsoluteUri && uri.Scheme == "https" && uri.Port == 443 &&
                uri.UserInfo.Length == 0 && uri.Fragment.Length == 0 &&
                (uri.Host == "github.com" || uri.Host == "release-assets.githubusercontent.com" || uri.Host == "objects.githubusercontent.com");
        }

        internal static async Task<DownloadResponse> OpenAsync(Uri uri, CancellationToken cancel)
        {
            var request = (HttpWebRequest)WebRequest.Create(uri);
            request.AllowAutoRedirect = false;
            request.Timeout = 60000; request.ReadWriteTimeout = 60000;
            request.AutomaticDecompression = DecompressionMethods.None;
            request.UserAgent = "Knot-Setup";
            HttpWebResponse response;
            try
            {
                using (cancel.Register(request.Abort))
                    response = (HttpWebResponse)await request.GetResponseAsync().ConfigureAwait(false);
            }
            catch (WebException error) { if (error.Response != null) error.Response.Close(); throw; }
            try
            {
                return new DownloadResponse { Status = (int)response.StatusCode, Length = response.ContentLength,
                    Location = response.Headers["Location"], Body = response.GetResponseStream(),
                    Abort = request.Abort, Close = response.Close };
            }
            catch { response.Close(); throw; }
        }

        // The injected response opener and short budgets are used only by fresh offline fixtures.
        // URI and byte policies apply equally to every transport and redirect.
        internal static async Task FetchAsync(Uri uri, string path, long expectedBytes, CancellationToken cancel,
            Action<long> progress, Func<Uri, CancellationToken, Task<DownloadResponse>> open, int idleMs, int deadlineMs)
        {
            if (expectedBytes < 1 || expectedBytes > 268435456 || idleMs < 1 || deadlineMs < 1)
                throw new ArgumentException("Invalid download limits.");
            bool created = false, complete = false;
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel))
            {
                deadline.CancelAfter(deadlineMs);
                try
                {
                    for (int redirects = 0; redirects <= 5; redirects++)
                    {
                        deadline.Token.ThrowIfCancellationRequested();
                        if (!SafeUri(uri)) throw new IOException("설치 파일의 다운로드 주소를 확인하지 못했습니다.");
                        DownloadResponse response;
                        using (var idle = CancellationTokenSource.CreateLinkedTokenSource(deadline.Token))
                        {
                            idle.CancelAfter(idleMs);
                            try { response = await open(uri, idle.Token).ConfigureAwait(false); }
                            catch { ThrowTimeout(cancel, deadline, idle); throw; }
                        }
                        using (response)
                        {
                            deadline.Token.ThrowIfCancellationRequested();
                            if (response.Status == 301 || response.Status == 302 || response.Status == 303 || response.Status == 307 || response.Status == 308)
                            {
                                Uri next;
                                if (redirects == 5 || String.IsNullOrEmpty(response.Location) || !Uri.TryCreate(uri, response.Location, out next) || !SafeUri(next))
                                    throw new IOException("설치 파일의 다운로드 주소를 확인하지 못했습니다.");
                                uri = next; continue;
                            }
                            if (response.Status != 200 || response.Length >= 0 && response.Length != expectedBytes)
                                throw new IOException("Sunshine 설치 파일 크기를 확인하지 못했습니다.");
                            using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
                            {
                                created = true;
                                var buffer = new byte[65536]; long total = 0;
                                while (true)
                                {
                                    int read;
                                    using (var idle = CancellationTokenSource.CreateLinkedTokenSource(deadline.Token))
                                    {
                                        idle.CancelAfter(idleMs);
                                        using (idle.Token.Register(response.Abort))
                                        {
                                            try { read = await response.Body.ReadAsync(buffer, 0, buffer.Length, idle.Token).ConfigureAwait(false); }
                                            catch { ThrowTimeout(cancel, deadline, idle); throw; }
                                        }
                                    }
                                    deadline.Token.ThrowIfCancellationRequested();
                                    if (read == 0) break;
                                    // Reject a chunk before any of its bytes can exceed the pinned bound on disk.
                                    if (read > expectedBytes - total) throw new IOException("Sunshine 설치 파일이 예상 크기를 초과했습니다.");
                                    await output.WriteAsync(buffer, 0, read, deadline.Token).ConfigureAwait(false);
                                    total += read; progress(total);
                                }
                                if (total != expectedBytes) throw new IOException("Sunshine 설치 파일을 끝까지 내려받지 못했습니다.");
                                await output.FlushAsync(deadline.Token).ConfigureAwait(false);
                            }
                            deadline.Token.ThrowIfCancellationRequested();
                            complete = true;
                            return;
                        }
                    }
                    throw new IOException("Sunshine 다운로드를 완료하지 못했습니다.");
                }
                catch
                {
                    cancel.ThrowIfCancellationRequested();
                    if (deadline.IsCancellationRequested) throw new TimeoutException("다운로드 제한 시간 10분을 넘었습니다. 네트워크를 확인한 뒤 다시 시도하세요.");
                    throw;
                }
                finally { if (created && !complete) File.Delete(path); }
            }
        }

        private static void ThrowTimeout(CancellationToken cancel, CancellationTokenSource deadline, CancellationTokenSource idle)
        {
            cancel.ThrowIfCancellationRequested();
            if (deadline.IsCancellationRequested) throw new TimeoutException("다운로드 제한 시간 10분을 넘었습니다. 네트워크를 확인한 뒤 다시 시도하세요.");
            if (idle.IsCancellationRequested) throw new TimeoutException("60초 동안 다운로드가 진행되지 않았습니다. 네트워크를 확인한 뒤 다시 시도하세요.");
        }
    }
}
'@
if (-not ('DeskBridge.Setup.DownloadOperation' -as [type])) { Add-Type -TypeDefinition $source }
function Start-SetupDownload([string] $Url, [string] $Path, [long] $ExpectedBytes) {
    return [DeskBridge.Setup.DownloadOperation]::new($Url, $Path, $ExpectedBytes)
}
Export-ModuleMember -Function Start-SetupDownload
