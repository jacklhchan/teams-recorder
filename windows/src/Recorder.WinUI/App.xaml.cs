using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using TeamsRecorder.Windows.Application.Diagnostics;
using WinUiApplication = Microsoft.UI.Xaml.Application;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Hosts the Teams Recorder desktop window.
/// </summary>
public partial class App : WinUiApplication
{
    private const string MainInstanceKey = "TeamsRecorder.Main";
    private Window? window;
    private AppInstance? mainInstance;
    private readonly IRecorderCrashMarkerStore crashMarkers = new RecorderCrashMarkerStore();

    public App()
    {
        InitializeComponent();
        UnhandledException += OnXamlUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandledException;
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        mainInstance = AppInstance.FindOrRegisterForKey(MainInstanceKey);
        if (!mainInstance.IsCurrent)
        {
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            await mainInstance.RedirectActivationToAsync(activation);
            Exit();
            return;
        }

        mainInstance.Activated += OnMainInstanceActivated;
        window = new MainWindow();
        window.Activate();
    }

    private void OnMainInstanceActivated(object? sender, AppActivationArguments args)
    {
        if (window is not MainWindow main)
        {
            return;
        }

        _ = main.DispatcherQueue.TryEnqueue(main.ShowAndActivate);
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
