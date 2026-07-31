using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

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
}
