using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Windows.Graphics;
using WinRT.Interop;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// An always-on-top auxiliary window shown without taking keyboard focus from
/// Teams. It has only lifecycle-specific actions: cancel, stop, and capture.
/// </summary>
public sealed partial class RecordingOverlayWindow : Window
{
    private const int GwlExStyle = -20;
    private const nint WsExToolWindow = 0x00000080;
    private const nint WsExNoActivate = 0x08000000;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpShowWindow = 0x0040;
    private const int SwHide = 0;
    private static readonly nint HwndTopmost = new(-1);

    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer indicatorTimer;
    private bool indicatorVisible = true;
    private bool isClosing;
    private bool isApplyingPresentation;

    public RecordingOverlayWindow()
    {
        InitializeComponent();

        AppWindow.Resize(new SizeInt32(448, 276));
        AppWindow.IsShownInSwitchers = false;
        MoveToWorkingAreaCorner();
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsAlwaysOnTop = true;
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.SetBorderAndTitleBar(hasBorder: false, hasTitleBar: false);
        }

        ApplyNoActivateStyle();
        AppWindow.Closing += OnAppWindowClosing;
        indicatorTimer = DispatcherQueue.CreateTimer();
        indicatorTimer.Interval = TimeSpan.FromMilliseconds(550);
        indicatorTimer.Tick += OnIndicatorTimerTick;
        ApplyPresentation(RecordingOverlayPresentation.Countdown(0));
    }

    public event EventHandler? CancelRequested;
    public event EventHandler? StopRequested;
    public event EventHandler<TeamsWindowCaptureToggleRequestedEventArgs>? TeamsWindowCaptureToggleRequested;
    public event EventHandler<RecorderMicrophoneMuteToggleRequestedEventArgs>? RecorderMicrophoneMuteToggleRequested;

    internal void ApplyPresentation(RecordingOverlayPresentation presentation)
    {
        var isRecording = presentation.Mode == RecordingOverlayMode.Recording;
        var isFinalizing = presentation.Mode == RecordingOverlayMode.Finalizing;
        isApplyingPresentation = true;
        try
        {
            StatusText.Text = isFinalizing ? "正在完成錄音" : isRecording ? "錄音中" : "自動錄音即將開始";
            StatusDetailText.Text = isFinalizing
                ? presentation.FinalizingStatus ?? "正在安全寫入檔案；完成後會自動關閉。"
                : isRecording ? "正在擷取 Teams／系統輸出與麥克風。" : "錄音控制器不會取得 Teams 焦點";
            CountdownCard.Visibility = isRecording || isFinalizing ? Visibility.Collapsed : Visibility.Visible;
            CountdownText.Text = $"倒數 {presentation.RemainingSeconds} 秒";
            ElapsedText.Visibility = isRecording && presentation.Elapsed is not null ? Visibility.Visible : Visibility.Collapsed;
            ElapsedText.Text = presentation.Elapsed is { } elapsed ? elapsed.ToString(@"hh\:mm\:ss") : string.Empty;
            ActionButton.Visibility = isFinalizing ? Visibility.Collapsed : Visibility.Visible;
            ActionButton.IsEnabled = !isFinalizing;
            ActionButton.Content = isRecording ? "停止" : "取消";
            ActionButton.AccessKey = isRecording ? "停止錄音" : "取消自動錄音";
            AutomationProperties.SetName(ActionButton, isRecording ? "停止錄音" : "取消自動錄音");

            SourcesPanel.Visibility = isRecording || isFinalizing ? Visibility.Visible : Visibility.Collapsed;
            SystemAudioStatusText.Text = InputStatusText(presentation.SystemAudioStatus);
            MicrophoneScopeText.Text = presentation.IsRecorderMicrophoneMuted
                ? "Recorder 麥克風已靜音；不會同步 Teams"
                : "僅影響 Recorder，不會同步 Teams";
            MicrophoneIcon.Glyph = presentation.IsRecorderMicrophoneMuted ? "\uE74F" : "\uE720";
            SystemWaveform.Value = WaveformValue(presentation.SystemAudioStatus);
            MicrophoneWaveform.Value = presentation.IsRecorderMicrophoneMuted ? 0 : WaveformValue(presentation.MicrophoneStatus);
            MicrophoneMuteButton.Visibility = isRecording ? Visibility.Visible : Visibility.Collapsed;
            MicrophoneMuteButton.IsEnabled = isRecording && presentation.MicrophoneStatus != RecordingOverlayInputStatus.Disconnected;
            MicrophoneMuteButton.Content = presentation.IsRecorderMicrophoneMuted ? "取消靜音" : "靜音";
            AutomationProperties.SetName(
                MicrophoneMuteButton,
                presentation.IsRecorderMicrophoneMuted ? "取消 Recorder 麥克風靜音" : "將 Recorder 麥克風靜音");

            // Finalizing is deliberately inert: it is neither dismissible nor
            // able to change the active A/V target while the file is written.
            ScreenCaptureCard.Visibility = isRecording ? Visibility.Visible : Visibility.Collapsed;
            TeamsWindowCaptureToggle.IsEnabled = isRecording && presentation.CanToggleTeamsWindowCapture;
            TeamsWindowCaptureToggle.IsOn = presentation.IsTeamsWindowCaptureEnabled;
            TeamsWindowCaptureStatusText.Text = presentation.TeamsWindowCaptureStatus ?? "可在錄音期間切換";
        }
        finally
        {
            // Setting IsOn raises Toggled in WinUI. A presentation update is
            // not a user request, so it must not start another transition.
            isApplyingPresentation = false;
        }

        if (isRecording)
        {
            indicatorVisible = true;
            RecordingIndicator.Opacity = 1;
            indicatorTimer.Start();
        }
        else
        {
            indicatorTimer.Stop();
            indicatorVisible = true;
            RecordingIndicator.Opacity = 1;
        }
    }

    internal void ShowNonActivating()
    {
        var hwnd = WindowNative.GetWindowHandle(this);
        _ = SetWindowPos(hwnd, HwndTopmost, 0, 0, 0, 0,
            SwpNoSize | SwpNoMove | SwpNoActivate | SwpShowWindow);
    }

    private void MoveToWorkingAreaCorner()
    {
        var displayArea = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest);
        var workArea = displayArea.WorkArea;
        const int margin = 20;
        AppWindow.Move(new PointInt32(
            Math.Max(workArea.X + margin, workArea.X + workArea.Width - AppWindow.Size.Width - margin),
            Math.Max(workArea.Y + margin, workArea.Y + workArea.Height - AppWindow.Size.Height - margin)));
    }

    internal void HideNonActivating()
    {
        indicatorTimer.Stop();
        _ = ShowWindow(WindowNative.GetWindowHandle(this), SwHide);
    }

    internal void CloseNonActivating()
    {
        isClosing = true;
        indicatorTimer.Stop();
        Close();
    }

    private void OnActionButtonClick(object sender, RoutedEventArgs e)
    {
        if (ActionButton.Content is string action && action == "停止")
        {
            StopRequested?.Invoke(this, EventArgs.Empty);
            return;
        }

        CancelRequested?.Invoke(this, EventArgs.Empty);
    }

    private void OnMicrophoneMuteButtonClick(object sender, RoutedEventArgs e)
    {
        if (MicrophoneMuteButton.IsEnabled && MicrophoneMuteButton.Content is string action)
        {
            RecorderMicrophoneMuteToggleRequested?.Invoke(
                this,
                new RecorderMicrophoneMuteToggleRequestedEventArgs(action == "靜音"));
        }
    }

    private void OnTeamsWindowCaptureToggleToggled(object sender, RoutedEventArgs e)
    {
        if (isApplyingPresentation)
        {
            return;
        }

        TeamsWindowCaptureToggleRequested?.Invoke(
            this,
            new TeamsWindowCaptureToggleRequestedEventArgs(TeamsWindowCaptureToggle.IsOn));
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (isClosing)
        {
            return;
        }

        // Never expose a generic close route while the recording lifecycle owns this window.
        args.Cancel = true;
    }

    private void OnIndicatorTimerTick(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        indicatorVisible = !indicatorVisible;
        RecordingIndicator.Opacity = indicatorVisible ? 1 : 0.25;
    }

    private static string InputStatusText(RecordingOverlayInputStatus status) => status switch
    {
        RecordingOverlayInputStatus.Signal => "有訊號",
        RecordingOverlayInputStatus.Quiet => "安靜",
        RecordingOverlayInputStatus.Muted => "已靜音",
        RecordingOverlayInputStatus.Disconnected => "已中斷",
        _ => "未知",
    };

    private static double WaveformValue(RecordingOverlayInputStatus status) => status switch
    {
        RecordingOverlayInputStatus.Signal => 62,
        RecordingOverlayInputStatus.Quiet => 12,
        _ => 0,
    };

    private void ApplyNoActivateStyle()
    {
        var hwnd = WindowNative.GetWindowHandle(this);
        var existingStyle = GetWindowLongPtr(hwnd, GwlExStyle);
        _ = SetWindowLongPtr(hwnd, GwlExStyle, existingStyle | WsExToolWindow | WsExNoActivate);
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint GetWindowLongPtr(nint hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetWindowLongPtr(nint hWnd, int nIndex, nint dwNewLong);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(nint hWnd, nint hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(nint hWnd, int nCmdShow);
}
