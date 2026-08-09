using Microsoft.UI.Xaml;
using TeamsRecorder.Windows.Application.Diagnostics;
using WinUiApplication = Microsoft.UI.Xaml.Application;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Hosts the Teams Recorder desktop window.
/// </summary>
public partial class App : WinUiApplication
{
    private Window? window;
    private readonly IRecorderCrashMarkerStore crashMarkers = new RecorderCrashMarkerStore();

    public App()
    {
        InitializeComponent();
        UnhandledException += OnXamlUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandledException;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        window.Activate();
    }

    private void OnXamlUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs args) =>
        WriteCrashMarker("xaml-unhandled", args.Exception?.GetType());

    private void OnDomainUnhandledException(object sender, System.UnhandledExceptionEventArgs args) =>
        WriteCrashMarker("app-domain-unhandled", (args.ExceptionObject as Exception)?.GetType());

    private void WriteCrashMarker(string source, Type? exceptionType)
    {
        RecorderCrashContext context;
        try
        {
            context = window is MainWindow main
                ? main.CaptureCrashContext()
                : new RecorderCrashContext("initializing", null, null, false, "none");
        }
        catch
        {
            context = new RecorderCrashContext("unknown", null, null, false, "none");
        }
        crashMarkers.WriteBestEffort(context, source, exceptionType);
    }
}
