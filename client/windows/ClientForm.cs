// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace DeskBridge.Reverse
{
    internal sealed class ClientForm : Form
    {
        private readonly EngineStore store;
        private readonly HostPlatform platform;
        private readonly TextBox status = new TextBox();
        private readonly TextBox link = new TextBox();
        private readonly TextBox manual = new TextBox();
        private readonly ComboBox candidates = new ComboBox();
        private readonly ComboBox resolution = new ComboBox();
        private readonly ComboBox fps = new ComboBox();
        private readonly ComboBox bitrate = new ComboBox();
        private readonly CheckBox fullscreen = new CheckBox();
        private readonly CheckBox macCommandKeys = new CheckBox();
        private readonly CheckBox advanced = new CheckBox();
        private readonly FlowLayoutPanel manualPanel = new FlowLayoutPanel();
        private readonly Label target = new Label();
        private readonly Button install = new Button(), pair = new Button(), connect = new Button(), cancel = new Button();
        private readonly ProgressBar progress = new ProgressBar();
        private readonly List<Control> changing = new List<Control>();
        private readonly List<Label> wrapping = new List<Label>();
        private readonly TableLayoutPanel content = new TableLayoutPanel();
        private CancellationTokenSource operation;
        private EngineProcess ownedProcess;
        private string selectedAddress;
        private bool busy, closing, allowClose;

        internal ClientForm(HostPlatform platform = HostPlatform.Mac)
        {
            this.platform = platform;
            Text = HostText("DeskBridge · Mac 열기");
            Font = new Font("Malgun Gothic", 9.5f);
            AutoScaleMode = AutoScaleMode.Dpi; AutoScaleDimensions = new SizeF(96, 96);
            StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(1000, 790); MinimumSize = new Size(720, 540);
            BackColor = Color.FromArgb(246, 247, 249);
            store = new EngineStore();
            Build();
            status.Text = HostText("Mac에서 ‘이 Mac 공유’를 시작한 뒤 QR/링크 또는 같은 Wi-Fi 검색으로 주소를 선택하세요. 아직 연결을 확인하지 않았습니다.");
            Shown += delegate
            {
                Rectangle area = Screen.FromControl(this).WorkingArea;
                MinimumSize = new Size(Math.Min(MinimumSize.Width, area.Width), Math.Min(MinimumSize.Height, area.Height));
                Size = new Size(Math.Min(Width, area.Width), Math.Min(Height, area.Height));
                Location = new Point(Math.Max(area.Left, Math.Min(Left, area.Right - Width)), Math.Max(area.Top, Math.Min(Top, area.Bottom - Height)));
                UpdateWrapping();
            };
            FormClosing += OnClosing;
            UpdateControls();
        }

        private string HostText(string text)
        {
            if (platform == HostPlatform.Mac) return text;
            if (text.Contains("화면 녹화") || text.StartsWith("Mac에서 ‘이 Mac 공유’"))
                return "Ubuntu 24.04 LTS amd64의 X11 데스크톱에서 DeskBridge 공유를 시작한 뒤 QR/링크 또는 같은 Wi-Fi 검색으로 주소를 선택하세요. Linux 파일 전송·Wayland·로그인 화면은 아직 지원하지 않습니다. PIN으로 PC를 확인하세요.";
            if (text.Contains("Ctrl↔Command")) return "Linux 연결은 시스템 키 전달을 끈 상태로 시작합니다. Windows 키·Alt+Tab 등은 로컬 Windows에서 처리될 수 있습니다. Ctrl은 Control, Alt는 Alt로 사용하며 입력 결과는 실제 연결에서 확인하세요.";
            if (text.Contains("FileVault")) return "로그인 전 화면·잠금 해제·절전 복귀·모니터 없는 사용은 보장하지 않습니다. 실제 연결 상태와 페어링 오류는 Moonlight 창에서 확인하세요.";
            return text.Replace("Mac Command", "Super").Replace("Mac", "Linux").Replace("Option", "Alt");
        }

        private void Build()
        {
            var footer = new Panel { Dock = DockStyle.Bottom, Height = 118, Padding = new Padding(20, 10, 20, 14), BackColor = Color.White };
            cancel.Text = "작업 취소"; cancel.AutoSize = true; cancel.Dock = DockStyle.Right; cancel.MinimumSize = new Size(110, 0);
            cancel.Click += delegate { CancelOwned(); };
            status.ReadOnly = true; status.Multiline = true; status.ScrollBars = ScrollBars.Vertical; status.Dock = DockStyle.Fill;
            status.BorderStyle = BorderStyle.None; status.BackColor = Color.White; status.AccessibleName = "현재 작업 상태";
            footer.Controls.Add(status); footer.Controls.Add(cancel); Controls.Add(footer);
            var sidebar = new Panel { Dock = DockStyle.Left, Width = 168, BackColor = Color.FromArgb(234, 237, 241), Padding = new Padding(20, 26, 12, 0) };
            sidebar.Controls.Add(new Label { Dock = DockStyle.Top, AutoSize = true, Text = HostText("DeskBridge\r\n\r\nMac 열기\r\n\r\n① 주소 선택\r\n② PIN 연결\r\n③ 화면 열기"), Font = new Font(Font, FontStyle.Bold) });
            Controls.Add(sidebar);
            var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(24) };
            content.ColumnCount = 1; content.RowCount = 0; content.AutoSize = true; content.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            content.Dock = DockStyle.Top; content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            scroll.Controls.Add(content); Controls.Add(scroll); scroll.BringToFront();
            scroll.ClientSizeChanged += delegate { UpdateWrapping(); };
            Add(Heading(HostText("Windows에서 Mac 열기")));
            Add(Description(HostText("같은 Wi-Fi 또는 이미 연결된 Tailscale을 사용합니다. Mac에서 DeskBridge의 ‘이 Mac 공유’를 켜고 화면 녹화·손쉬운 사용 권한을 허용하세요. 로그인한 Mac의 Desktop을 엽니다.")));

            Add(Heading(HostText("1. Mac 주소 선택")));
            Add(Description("QR·검색 결과는 미확인 주소 안내입니다. 선택만으로 페어링하거나 접속하지 않습니다."));
            link.Multiline = true; link.Height = 65; link.MaxLength = 1536; link.Dock = DockStyle.Fill; link.AccessibleName = HostText("Mac 연결 링크");
            Add(link); changing.Add(link);
            var entryButtons = Row();
            entryButtons.Controls.Add(ActionButton("링크 미리보기", delegate { PreviewLink(); }));
            entryButtons.Controls.Add(ActionButton("QR 이미지 가져오기…", delegate { ImportQr(); }));
            entryButtons.Controls.Add(ActionButton("같은 Wi-Fi에서 찾기", async delegate { await DiscoverAsync(); }));
            Add(entryButtons);
            candidates.DropDownStyle = ComboBoxStyle.DropDownList; candidates.Dock = DockStyle.Fill;
            candidates.AccessibleName = HostText("미확인 Mac 주소 후보"); Add(candidates); changing.Add(candidates);
            var choose = Row(); choose.Controls.Add(ActionButton("선택한 주소 사용", delegate { ChooseCandidate(); })); Add(choose);
            advanced.Text = "고급: IPv4 주소 직접 입력"; advanced.AutoSize = true;
            advanced.CheckedChanged += delegate { manualPanel.Visible = advanced.Checked; }; changing.Add(advanced); Add(advanced);
            manual.Width = 190; manual.MaxLength = 15; manual.AccessibleName = HostText("Mac의 LAN 또는 Tailscale IPv4 주소");
            manualPanel.AutoSize = true; manualPanel.WrapContents = true; manualPanel.Visible = false;
            manualPanel.Controls.Add(manual); manualPanel.Controls.Add(ActionButton("이 주소 사용", delegate { ChooseManual(); }));
            changing.Add(manual); Add(manualPanel);
            target.AutoSize = true; target.Text = HostText("선택한 Mac 없음 · 연결 미확인"); target.Font = new Font(Font, FontStyle.Bold); wrapping.Add(target); Add(target);
            Add(Description("LAN과 Tailscale 주소는 별도 연결로 보관해 각각 PIN 승인이 필요할 수 있습니다. 저장된 인증서를 다른 주소로 자동 복사하지 않습니다."));

            Add(Heading("2. 화면 엔진과 PIN 연결"));
            Add(Description("처음 한 번 공식 Moonlight Portable " + EnginePin.Version + "를 인터넷에서 받습니다. 고정 크기·SHA-256과 모든 엔진 파일을 확인하며 관리자 권한은 사용하지 않습니다. 기존 Moonlight 설정과 분리해 이 앱 전용 폴더에 저장합니다."));
            Add(Description(HostText("화면은 선택한 Mac에 직접 연결합니다. Moonlight는 별도로 호환성·게임패드 목록·업데이트 유무를 온라인에서 조회할 수 있습니다. 이 프리뷰는 보안 서명이 없으며, 파일 전송 기능은 역방향에서 아직 지원하지 않습니다.")));
            var engineActions = Row();
            install.Text = "화면 엔진 받기"; install.AutoSize = true; install.Click += async delegate { await InstallAsync(); }; engineActions.Controls.Add(install);
            pair.Text = HostText("PIN으로 Mac 연결"); pair.AutoSize = true; pair.Click += async delegate { await LaunchAsync(true); }; engineActions.Controls.Add(pair); Add(engineActions);
            progress.Minimum = 0; progress.Maximum = 100; progress.Visible = false; progress.Dock = DockStyle.Fill; Add(progress);
            Add(Description(HostText("PIN은 Moonlight 창에서 표시됩니다. 선택한 Mac의 Sunshine 설정 화면에 직접 입력하고 기기를 승인하세요. QR·링크나 프로그램 종료 코드만으로 Mac의 신원을 확인했다고 표시하지 않습니다.")));

            Add(Heading(HostText("3. Mac 화면 열기")));
            var settings = Row();
            ConfigureChoice(resolution, new[] { "1920x1080", "2560x1440", "1280x720" }, 125, "해상도");
            ConfigureChoice(fps, new[] { "60", "30" }, 65, "초당 프레임");
            ConfigureChoice(bitrate, new[] { "20000", "10000", "40000" }, 90, "전송률 Kbps");
            settings.Controls.Add(new Label { Text = "해상도", AutoSize = true, Margin = new Padding(0, 7, 6, 0) }); settings.Controls.Add(resolution);
            settings.Controls.Add(new Label { Text = "FPS", AutoSize = true, Margin = new Padding(8, 7, 6, 0) }); settings.Controls.Add(fps);
            settings.Controls.Add(new Label { Text = "Kbps", AutoSize = true, Margin = new Padding(8, 7, 6, 0) }); settings.Controls.Add(bitrate);
            fullscreen.Text = "전체 화면"; fullscreen.AutoSize = true; fullscreen.Checked = true; settings.Controls.Add(fullscreen); changing.Add(fullscreen); Add(settings);
            macCommandKeys.Text = HostText("Windows 키를 Mac Command로 보내기 (전체 화면)");
            macCommandKeys.Visible = platform == HostPlatform.Mac; macCommandKeys.AutoSize = true; changing.Add(macCommandKeys); Add(macCommandKeys);
            fullscreen.CheckedChanged += delegate { if (!fullscreen.Checked) macCommandKeys.Checked = false; macCommandKeys.Enabled = !busy && !closing && fullscreen.Checked && platform == HostPlatform.Mac; };
            var streamActions = Row(); connect.Text = HostText("Mac 화면 열기"); connect.AutoSize = true; connect.Click += async delegate { await LaunchAsync(false); }; streamActions.Controls.Add(connect); Add(streamActions);
            Add(Description(HostText("기본은 Win+Ctrl+←/→ 등 Windows 단축키를 유지합니다. 위 옵션을 켜면 Windows 키가 Mac Command로 전달되고 Alt+Tab 같은 조합도 Mac으로 갈 수 있습니다. Ctrl은 Mac Control, Alt는 Option이며 Ctrl↔Command 자동 교환은 하지 않습니다.")));
            Add(Description(HostText("화면에서 Ctrl+Alt+Shift+K로 시스템 키 전달을 켜고 끌 수 있고, Ctrl+Alt+Shift+Q로 화면 연결을 닫습니다. 먼저 전달을 끄면 Windows 데스크톱을 전환할 수 있습니다. 한/영 전환은 Mac 입력기 설정을 확인하세요. 다른 앱을 종료하겠다는 Moonlight 안내는 취소하세요.")));
            Add(Description(HostText("로그인 전 화면·FileVault·잠금 해제·절전 복귀·모니터 없는 사용은 보장하지 않습니다. 실제 연결 상태와 페어링 오류는 Moonlight 창에서 확인하세요.")));
        }

        private void Add(Control control)
        {
            control.Margin = new Padding(0, 0, 0, 12);
            content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            content.Controls.Add(control, 0, content.RowCount++);
        }
        private Label Heading(string text) { return new Label { Text = text, AutoSize = true, Font = new Font(Font.FontFamily, 13f, FontStyle.Bold) }; }
        private Label Description(string text) { var label = new Label { Text = text, AutoSize = true, ForeColor = Color.FromArgb(75, 82, 94) }; wrapping.Add(label); return label; }
        private FlowLayoutPanel Row() { return new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = true, Dock = DockStyle.Fill, Margin = new Padding(0) }; }
        private Button ActionButton(string text, EventHandler handler)
        { var button = new Button { Text = text, AutoSize = true, Padding = new Padding(4) }; button.Click += handler; changing.Add(button); return button; }
        private void ConfigureChoice(ComboBox box, string[] values, int width, string name)
        { box.DropDownStyle = ComboBoxStyle.DropDownList; box.Items.AddRange(values); box.SelectedIndex = 0; box.Width = width; box.AccessibleName = name; changing.Add(box); }
        private void UpdateWrapping()
        {
            if (content.Parent == null) return;
            int width = Math.Max(180, content.Parent.ClientSize.Width - content.Parent.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth - 8);
            content.Width = width;
            foreach (Label label in wrapping) label.MaximumSize = new Size(width, 0);
        }

        private void PreviewLink()
        {
            if (busy) return;
            try
            {
                ReverseInvitation invitation = ConnectionPolicy.Parse(link.Text);
                ConnectionPolicy.RequireRole(invitation, platform);
                candidates.Items.Clear();
                foreach (string address in invitation.Addresses) candidates.Items.Add(new CandidateItem(invitation.Name, address));
                candidates.SelectedIndex = 0;
                SetStatus(HostText("링크를 읽었습니다. 미확인 Mac 주소를 확인하고 ‘선택한 주소 사용’을 누르세요. 아직 접속하지 않았습니다."));
            }
            catch (Exception error) { ShowFailure(error); }
        }
        private void ImportQr()
        {
            if (busy) return;
            using (var dialog = new OpenFileDialog { Title = HostText("Mac 연결 QR 이미지 선택"), Filter = "QR 이미지|*.png;*.jpg;*.jpeg;*.bmp", CheckFileExists = true, Multiselect = false, DereferenceLinks = false })
            {
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                try { link.Text = ReverseQrReader.Read(dialog.FileName); PreviewLink(); }
                catch (Exception error) { ShowFailure(error); }
            }
        }
        private void ChooseCandidate()
        {
            if (busy) return;
            var item = candidates.SelectedItem as CandidateItem;
            if (item == null) { SetStatus("QR/링크 또는 검색으로 주소 후보를 먼저 불러오세요."); return; }
            Choose(item.Name, item.Address);
        }
        private void ChooseManual()
        {
            if (busy) return;
            try { Choose(HostText("직접 입력한 Mac"), ConnectionPolicy.Address(manual.Text)); }
            catch (Exception error) { ShowFailure(error); }
        }
        private void Choose(string name, string address)
        {
            selectedAddress = ConnectionPolicy.Address(address);
            target.Text = name + " · " + selectedAddress + " · 연결 미확인";
            SetStatus(HostText("주소를 선택했습니다. Mac에서 ‘이 Mac 공유’를 시작한 뒤 PIN으로 연결하세요. 주소만으로 기기 신원을 신뢰하지 않습니다."));
            UpdateControls();
        }
        private async Task DiscoverAsync()
        {
            if (!Begin("같은 Wi-Fi의 Sunshine 주소 안내를 최대 8초 동안 찾는 중입니다. 기기에 접속하거나 포트를 스캔하지 않습니다.")) return;
            try
            {
                IList<ReverseCandidate> found = await ReverseDiscovery.FindAsync(operation.Token);
                if (closing) return;
                candidates.Items.Clear();
                foreach (ReverseCandidate item in found)
                    if (ConnectionPolicy.ValidName(item.Name)) candidates.Items.Add(new CandidateItem(item.Name, ConnectionPolicy.Address(item.Address)));
                if (candidates.Items.Count != 0) candidates.SelectedIndex = 0;
                SetStatus(candidates.Items.Count == 0 ? HostText("주변 주소 안내를 찾지 못했습니다. Mac의 QR/링크를 사용하세요. Tailscale 기기는 Wi-Fi 검색에 나타나지 않을 수 있습니다.") : HostText("검색 결과는 미확인 Sunshine 기기입니다. 사용하려는 Mac과 주소를 확인하고 선택하세요."));
            }
            catch (Exception error) { ShowFailure(error); }
            finally { End(); }
        }
        private async Task InstallAsync()
        {
            if (!Begin("고정 버전 Moonlight 화면 엔진을 다운로드하고 검증하는 중입니다.")) return;
            progress.Value = 0; progress.Visible = true;
            try
            {
                await store.InstallAsync(new Progress<int>(value => { if (!closing && !IsDisposed) progress.Value = Math.Max(0, Math.Min(100, value)); }), operation.Token);
                SetStatus(HostText("화면 엔진 파일 검증을 완료했습니다. 다음으로 Mac의 PIN 승인을 진행하세요. 아직 Mac 연결은 확인하지 않았습니다."));
            }
            catch (Exception error) { ShowFailure(error); }
            finally { progress.Visible = false; End(); }
        }
        private async Task LaunchAsync(bool pairing)
        {
            if (selectedAddress == null || !store.Installed || busy) return;
            string address = selectedAddress;
            string[] arguments;
            try
            {
                arguments = pairing ? EngineCommands.Pair(address) : EngineCommands.Stream(address, (string)resolution.SelectedItem,
                    Int32.Parse((string)fps.SelectedItem), Int32.Parse((string)bitrate.SelectedItem), fullscreen.Checked, ConnectionPolicy.MacCommandAllowed(platform, fullscreen.Checked, macCommandKeys.Checked));
            }
            catch (Exception error) { ShowFailure(error); return; }
            if (!Begin("화면 엔진의 모든 파일을 검증하는 중입니다.")) return;
            try
            {
                using (EngineLease lease = await Task.Run(() => store.Verify(operation.Token), operation.Token))
                {
                    using (ProfileLease profile = EngineProfile.Prepare(store.Root, address))
                    {
                    operation.Token.ThrowIfCancellationRequested();
                    using (var child = new EngineProcess())
                    {
                        ownedProcess = child;
                        SetStatus(pairing ? HostText("Moonlight의 PIN 연결 창을 실행했습니다. PIN을 선택한 Mac의 Sunshine에 직접 입력하세요. 실제 결과는 Moonlight 창에서 확인합니다.") : "Moonlight 화면 창을 실행했습니다. 연결 상태는 그 창에서 확인하세요. ‘작업 취소’는 이 앱이 실행한 로컬 화면 엔진만 종료합니다.");
                        int exit = await child.RunAsync(lease, profile.Path, arguments, operation.Token);
                        SetStatus(exit == 0 ? (pairing ? HostText("PIN 연결 창이 종료되었습니다. Moonlight에서 성공을 확인했다면 ‘Mac 화면 열기’를 누르세요.") : HostText("화면 엔진이 종료되었습니다. Mac의 앱은 종료 요청하지 않았습니다.")) : HostText("화면 엔진이 정상 완료되지 않았습니다. Moonlight의 오류 안내와 Mac의 공유 상태·권한을 확인한 뒤 다시 시도하세요."));
                    }
                    }
                }
            }
            catch (Exception error) { ShowFailure(error); }
            finally { ownedProcess = null; End(); }
        }

        private bool Begin(string message)
        { if (busy || closing) return false; busy = true; operation = new CancellationTokenSource(); SetStatus(message); UpdateControls(); return true; }
        private void End()
        {
            if (operation != null) { operation.Dispose(); operation = null; }
            busy = false; UpdateControls();
            if (closing) { allowClose = true; Close(); }
        }
        private void CancelOwned()
        {
            if (operation != null && !operation.IsCancellationRequested) { SetStatus("작업을 취소하고 이 앱이 실행한 로컬 작업만 정리하는 중입니다."); operation.Cancel(); }
            if (ownedProcess != null) ownedProcess.Stop();
            cancel.Enabled = false;
        }
        private void OnClosing(object sender, FormClosingEventArgs args)
        {
            if (allowClose || !busy) return;
            args.Cancel = true; closing = true; CancelOwned();
        }
        private void UpdateControls()
        {
            foreach (Control control in changing) control.Enabled = !busy && !closing;
            if (platform != HostPlatform.Mac) macCommandKeys.Checked = false;
            macCommandKeys.Enabled = !busy && !closing && fullscreen.Checked && platform == HostPlatform.Mac;
            install.Enabled = !busy && !closing; install.Text = store.Installed ? "화면 엔진 파일 다시 확인" : "화면 엔진 받기";
            pair.Enabled = connect.Enabled = !busy && !closing && store.Installed && selectedAddress != null;
            cancel.Enabled = busy && !closing; cancel.Visible = busy;
        }
        private void SetStatus(string text) { if (!IsDisposed) status.Text = text; }
        private void ShowFailure(Exception error)
        {
            SetStatus(ReverseErrors.ForOperation(error));
        }
        private sealed class CandidateItem
        {
            internal readonly string Name, Address;
            internal CandidateItem(string name, string address) { Name = name; Address = address; }
            public override string ToString() { return Name + " · " + Address + " · 미확인"; }
        }
    }
}
