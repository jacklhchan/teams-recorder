using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using WinRT.Interop;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// An always-on-top auxiliary window shown without taking keyboard focus from
/// Teams. It has only lifecycle-specific actions: cancel, stop, and capture.
/// </summary>
public sealed partial class RecordingOverlayWindow : Window
{
    private const int DefaultWidthDips = 448;
    private const int DefaultHeightDips = 392;
    private const int MinimumWidthDips = 420;
    private const int MinimumHeightDips = 300;
    private const int CompactWidthDips = 300;
    private const int CompactHeightDips = 64;
    private const int GwlExStyle = -20;
    private const nint WsExToolWindow = 0x00000080;
    private const nint WsExNoActivate = 0x08000000;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpShowWindow = 0x0040;
    private const int SwHide = 0;
    private const uint WmNcLButtonDown = 0x00A1;
    private static readonly nint HtCaption = new(2);
    private static readonly nint HwndTopmost = new(-1);

    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer indicatorTimer;
    private bool indicatorVisible = true;
    private bool isClosing;
    private bool isApplyingPresentation;
    private bool isApplyingWindowSize;
    private bool isCompact;
    private RecordingOverlayMode currentMode = RecordingOverlayMode.Countdown;

    public RecordingOverlayWindow()
    {
        InitializeComponent();

        ResizeForCurrentDpi(resetToDefault: true);
        AppWindow.IsShownInSwitchers = false;
        MoveToWorkingAreaCorner();
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsAlwaysOnTop = true;
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);
        }

        ApplyNoActivateStyle();
        AppWindow.Changed += OnAppWindowChanged;
        AppWindow.Closing += OnAppWindowClosing;
        indicatorTimer = DispatcherQueue.CreateTimer();
        indicatorTimer.Interval = TimeSpan.FromMilliseconds(550);
        indicatorTimer.Tick += OnIndicatorTimerTick;
        ApplyPresentation(RecordingOverlayPresentation.Countdown(0));
    }

    public event EventHandler? CancelRequested;
    public event EventHandler? StopRequested;
    public event EventHandler<TeamsWindowCaptureToggleRequestedEventArgs>? TeamsWindowCaptureToggleRequested;
    public event EventHandler<TeamsWindowCaptureTargetRequestedEventArgs>? TeamsWindowCaptureTargetRequested;
    public event EventHandler? TeamsWindowCaptureRefreshRequested;

    internal void ApplyPresentation(RecordingOverlayPresentation presentation)
    {
        currentMode = presentation.Mode;
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
            ActionButton.Content = isRecording ? "停止錄音" : "取消";
            ActionButton.AccessKey = isRecording ? "停止錄音" : "取消自動錄音";
            AutomationProperties.SetName(ActionButton, isRecording ? "停止錄音" : "取消自動錄音");

            SourcesPanel.Visibility = isRecording || isFinalizing ? Visibility.Visible : Visibility.Collapsed;
            SystemAudioStatusText.Text = InputStatusText(presentation.SystemAudioStatus);
            MicrophoneScopeText.Text = presentation.IsRecorderMicrophoneMuted
                ? "Recorder 與虛擬麥克風已靜音"
                : presentation.IsVirtualMicrophoneReady
                    ? "同步輸入 Recorder 與虛擬麥克風"
                    : "輸入 Recorder；虛擬麥克風未就緒";
            MicrophoneIcon.Glyph = presentation.IsRecorderMicrophoneMuted ? "\uE74F" : "\uE720";
            SystemWaveform.Value = presentation.SystemAudioLevelPercent;
            MicrophoneWaveform.Value = presentation.IsRecorderMicrophoneMuted ? 0 : presentation.MicrophoneLevelPercent;
            ToolTipService.SetToolTip(MicrophoneScopeText, presentation.VirtualMicrophoneStatus);

            // Finalizing is deliberately inert: it is neither dismissible nor
            // able to change the active A/V target while the file is written.
            ScreenCaptureCard.Visibility = isRecording ? Visibility.Visible : Visibility.Collapsed;
            TeamsWindowCaptureToggle.IsEnabled = isRecording && presentation.CanToggleTeamsWindowCapture;
            TeamsWindowCaptureToggle.IsOn = presentation.IsTeamsWindowCaptureEnabled;
            TeamsWindowCaptureStatusText.Text = presentation.TeamsWindowCaptureStatus ?? "可在錄音期間切換";
            var choices = presentation.TeamsWindowChoices ?? Array.Empty<VideoCaptureWindowChoice>();
            if (!ReferenceEquals(TeamsWindowCaptureTargetSelector.ItemsSource, choices))
            {
                TeamsWindowCaptureTargetSelector.ItemsSource = choices;
            }
            TeamsWindowCaptureTargetSelector.IsEnabled =
                isRecording && presentation.CanToggleTeamsWindowCapture && choices.Count > 0;
            TeamsWindowCaptureTargetSelector.SelectedItem = presentation.SelectedTeamsWindow;
            TeamsWindowCaptureRefreshButton.IsEnabled =
                isRecording && presentation.CanToggleTeamsWindowCapture;
            ApplyCompactVisibility(isRecording, isFinalizing);
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

    private void OnAppWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (isApplyingWindowSize || (!args.DidSizeChange && !args.DidPositionChange))
        {
            return;
        }

        // AppWindow sizes are physical pixels while XAML measures in DIPs.
        // Re-evaluate the minimum after either a user resize or a move to a
        // monitor with a different scale factor.
        ResizeForCurrentDpi(resetToDefault: false);
    }

    private void ResizeForCurrentDpi(bool resetToDefault)
    {
        var dpi = GetDpiForWindow(WindowNative.GetWindowHandle(this));
        if (dpi == 0)
        {
            dpi = 96;
        }

        var width = ScaleForDpi(isCompact ? CompactWidthDips : DefaultWidthDips, dpi);
        var height = ScaleForDpi(isCompact ? CompactHeightDips : DefaultHeightDips, dpi);

        if (AppWindow.Size.Width == width && AppWindow.Size.Height == height)
        {
            return;
        }

        isApplyingWindowSize = true;
        try
        {
            AppWindow.Resize(new SizeInt32(width, height));
        }
        finally
        {
            isApplyingWindowSize = false;
        }
    }

    internal static int ScaleForDpi(int dips, uint dpi) =>
        Math.Max(1, (int)Math.Ceiling(dips * dpi / 96d));

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
        if (currentMode == RecordingOverlayMode.Recording)
        {
            // Disable synchronously so a double click cannot enqueue two safe
            // finalization requests before the ViewModel reaches Stopping.
            ActionButton.IsEnabled = false;
            StopRequested?.Invoke(this, EventArgs.Empty);
            return;
        }

        if (currentMode == RecordingOverlayMode.Countdown)
        {
            ActionButton.IsEnabled = false;
            CancelRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void OnHeaderPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(HeaderDragSurface).Properties.IsLeftButtonPressed ||
            IsInteractiveHeaderElement(e.OriginalSource as DependencyObject))
        {
            return;
        }

        // WS_EX_NOACTIVATE prevents reliable XAML pointer capture on this
        // auxiliary window. Hand the complete header (not a tiny handle) to
        // Windows' native caption move loop instead. Post rather than send the
        // message so this routed pointer event can unwind before the modal
        // native move loop begins; a synchronous SendMessage makes the header
        // feel stuck while WinUI is still dispatching the press.
        e.Handled = true;
        _ = ReleaseCapture();
        _ = PostMessage(
            WindowNative.GetWindowHandle(this),
            WmNcLButtonDown,
            HtCaption,
            nint.Zero);
    }

    private bool IsInteractiveHeaderElement(DependencyObject? source)
    {
        for (var current = source; current is not null && current != HeaderDragSurface; current = VisualTreeHelper.GetParent(current))
        {
            if (current is ButtonBase or Selector or Slider)
            {
                return true;
            }
        }

        return false;
    }

    private void OnCompactButtonClick(object sender, RoutedEventArgs e)
    {
        isCompact = !isCompact;
        ApplyCompactVisibility(
            currentMode == RecordingOverlayMode.Recording,
            currentMode == RecordingOverlayMode.Finalizing);
        ResizeForCurrentDpi(resetToDefault: true);
    }

    private void ApplyCompactVisibility(bool isRecording, bool isFinalizing)
    {
        StatusDetailText.Visibility = isCompact ? Visibility.Collapsed : Visibility.Visible;
        CountdownCard.Visibility = isCompact || isRecording || isFinalizing ? Visibility.Collapsed : Visibility.Visible;
        SourcesPanel.Visibility = isCompact || (!isRecording && !isFinalizing) ? Visibility.Collapsed : Visibility.Visible;
        ScreenCaptureCard.Visibility = isCompact || !isRecording ? Visibility.Collapsed : Visibility.Visible;
        ActionButton.Visibility = isCompact || isFinalizing ? Visibility.Collapsed : Visibility.Visible;
        CompactButton.Content = isCompact ? "□" : "—";
        AutomationProperties.SetName(CompactButton, isCompact ? "還原錄音控制器" : "最小化錄音控制器");
        ToolTipService.SetToolTip(CompactButton, isCompact ? "還原" : "最小化");
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

    private void OnTeamsWindowCaptureTargetSelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (isApplyingPresentation ||
            TeamsWindowCaptureTargetSelector.SelectedItem is not VideoCaptureWindowChoice choice)
        {
            return;
        }

        TeamsWindowCaptureTargetRequested?.Invoke(
            this,
            new TeamsWindowCaptureTargetRequestedEventArgs(choice.Target));
    }

    private void OnTeamsWindowCaptureRefreshClick(object sender, RoutedEventArgs e) =>
        TeamsWindowCaptureRefreshRequested?.Invoke(this, EventArgs.Empty);

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (isClosing)
        {
            AppWindow.Changed -= OnAppWindowChanged;
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

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(nint hWnd, nint hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(nint hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(nint hWnd, uint message, nint wParam, nint lParam);
}
