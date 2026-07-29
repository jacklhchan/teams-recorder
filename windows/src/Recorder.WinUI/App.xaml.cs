using Microsoft.UI.Xaml;
using WinUiApplication = Microsoft.UI.Xaml.Application;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Hosts the Teams Recorder desktop window.
/// </summary>
public partial class App : WinUiApplication
{
    private Window? window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        window.Activate();
    }
}
