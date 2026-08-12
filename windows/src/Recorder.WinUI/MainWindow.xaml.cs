using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;
using TeamsRecorder.Windows.Application.Diagnostics;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Hosts the capture page and stops the native recording session before exit.
/// </summary>
public sealed partial class MainWindow : Window
{
    private const double WorkAreaWidthRatio = 0.90;
    private const double WorkAreaHeightRatio = 0.88;
    private const double MinimumLogicalWidth = 960;
    private const double MinimumLogicalHeight = 700;
    private readonly TrayIconService trayIcon;
    private bool initialSizeApplied;
    private bool shutdownInProgress;
    private bool shutdownComplete;

    public MainWindow()
    {
        InitializeComponent();

        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        RootFrame.Navigate(typeof(MainPage));
        Activated += OnFirstActivated;
        AppWindow.Closing += OnAppWindowClosing;
        trayIcon = new TrayIconService(this, ShowFromTray, HideToTray, RequestExitFromTray);
    }

    private void OnFirstActivated(object sender, WindowActivatedEventArgs args)
    {
        if (initialSizeApplied)
        {
            return;
        }

        initialSizeApplied = true;
        Activated -= OnFirstActivated;
        ResizeForWorkingArea();
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            var scale = Math.Max(1d, RootFrame.XamlRoot?.RasterizationScale ?? 1d);
            presenter.PreferredMinimumWidth = (int)Math.Round(MinimumLogicalWidth * scale);
            presenter.PreferredMinimumHeight = (int)Math.Round(MinimumLogicalHeight * scale);
        }
    }

    private void ResizeForWorkingArea()
    {
        var displayArea = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest);
        var workArea = displayArea.WorkArea;
        var scale = Math.Max(1d, RootFrame.XamlRoot?.RasterizationScale ?? 1d);
        var width = Math.Max(1, (int)Math.Round(workArea.Width * WorkAreaWidthRatio));
        var height = Math.Max(1, (int)Math.Round(workArea.Height * WorkAreaHeightRatio));
        AppWindow.Resize(new SizeInt32(width, height));
    }

    private async void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (shutdownComplete)
        {
            return;
        }

        args.Cancel = true;
        if (!shutdownInProgress)
        {
            HideToTray();
            return;
        }

        try
        {
            if (RootFrame.Content is MainPage page)
            {
                await page.ShutdownAsync();
            }
        }
        finally
        {
            shutdownComplete = true;
            trayIcon.Dispose();
            Close();
        }
    }

    private void ShowFromTray() => trayIcon.ShowWindow();

    internal void ShowAndActivate()
    {
        trayIcon.ShowWindow();
        Activate();
    }

    private void HideToTray() => trayIcon.HideWindow();

    private void RequestExitFromTray()
    {
        if (shutdownInProgress || shutdownComplete)
        {
            return;
        }

        shutdownInProgress = true;
        Close();
    }

    internal RecorderCrashContext CaptureCrashContext() =>
        RootFrame.Content is MainPage page
            ? page.CaptureCrashContext()
            : new("initializing", null, null, false, "none");
}
