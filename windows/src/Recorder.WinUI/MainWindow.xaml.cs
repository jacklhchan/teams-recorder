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
    private readonly TrayIconService trayIcon;
    private bool shutdownInProgress;
    private bool shutdownComplete;

    public MainWindow()
    {
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Resize(new SizeInt32(1000, 760));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = 860;
            presenter.PreferredMinimumHeight = 680;
        }

        RootFrame.Navigate(typeof(MainPage));
        AppWindow.Closing += OnAppWindowClosing;
        trayIcon = new TrayIconService(this, ShowFromTray, HideToTray, RequestExitFromTray);
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
