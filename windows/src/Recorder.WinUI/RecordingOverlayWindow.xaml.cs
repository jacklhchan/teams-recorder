using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Windows.Graphics;
using WinRT.Interop;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// An always-on-top auxiliary window which is shown without taking keyboard
/// focus from Teams or another foreground application.
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

        AppWindow.Resize(new SizeInt32(420, 158));
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

    internal void ApplyPresentation(RecordingOverlayPresentation presentation)
    {
        var isRecording = presentation.Mode == RecordingOverlayMode.Recording;
        isApplyingPresentation = true;
        try
        {
        StatusText.Text = isRecording ? "錄音中" : "自動錄音即將開始";
        CountdownText.Visibility = isRecording ? Visibility.Collapsed : Visibility.Visible;
        CountdownText.Text = $"倒數 {presentation.RemainingSeconds} 秒";
        ActionButton.Content = isRecording ? "停止" : "取消";
        ActionButton.AccessKey = isRecording ? "停止錄音" : "取消自動錄音";
        AutomationProperties.SetName(ActionButton, isRecording ? "停止錄音" : "取消自動錄音");
        TeamsWindowCaptureToggle.Visibility = isRecording ? Visibility.Visible : Visibility.Collapsed;
        TeamsWindowCaptureToggle.IsEnabled = isRecording && presentation.CanToggleTeamsWindowCapture;
        TeamsWindowCaptureToggle.IsOn = presentation.IsTeamsWindowCaptureEnabled;
        TeamsWindowCaptureStatusText.Visibility = isRecording && !string.IsNullOrWhiteSpace(presentation.TeamsWindowCaptureStatus)
            ? Visibility.Visible : Visibility.Collapsed;
        TeamsWindowCaptureStatusText.Text = presentation.TeamsWindowCaptureStatus ?? string.Empty;
        }
        finally
        {
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
        _ = SetWindowPos(
            hwnd,
            HwndTopmost,
            0,
            0,
            0,
            0,
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

    private void OnTeamsWindowCaptureToggleToggled(object sender, RoutedEventArgs e)
    {
        if (!isApplyingPresentation)
        {
            TeamsWindowCaptureToggleRequested?.Invoke(this,
                new TeamsWindowCaptureToggleRequestedEventArgs(TeamsWindowCaptureToggle.IsOn));
        }
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (isClosing)
        {
            return;
        }

        // The indicator must not be dismissible while recording. Its explicit
        // action is Stop, and the primary window remains the app close target.
        args.Cancel = true;
    }

    private void OnIndicatorTimerTick(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        indicatorVisible = !indicatorVisible;
        RecordingIndicator.Opacity = indicatorVisible ? 1 : 0.25;
    }

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
    private static extern bool SetWindowPos(
        nint hWnd,
        nint hWndInsertAfter,
        int x,
        int y,
        int cx,
        int cy,
        uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(nint hWnd, int nCmdShow);
}
