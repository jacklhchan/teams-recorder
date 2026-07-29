using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Hosts the capture page and stops the native recording session before exit.
/// </summary>
public sealed partial class MainWindow : Window
{
    private bool shutdownInProgress;
    private bool shutdownComplete;

    public MainWindow()
    {
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.SetIcon("Assets/AppIcon.ico");

        RootFrame.Navigate(typeof(MainPage));
        AppWindow.Closing += OnAppWindowClosing;
    }

    private async void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (shutdownComplete)
        {
            return;
        }

        args.Cancel = true;
        if (shutdownInProgress)
        {
            return;
        }

        shutdownInProgress = true;
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
            Close();
        }
    }
}
