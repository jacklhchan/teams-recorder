using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TeamsRecorder.Windows.Application.Diagnostics;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Owns the app's single recording view model and routes it into four focused
/// workspaces. Child views are presentation-only and inherit this DataContext.
/// </summary>
public sealed partial class MainPage : Page
{
    private readonly RecordingViewModel viewModel;
    private readonly IRecordingOverlayPresenter recordingOverlayPresenter;
    private bool isShutdown;

    public MainPage()
    {
        InitializeComponent();
        WorkspaceNavigation.SelectedItem = RecordNavigationItem;
        ShowWorkspace("Record");

        viewModel = new RecordingViewModel();
        viewModel.InitializePlayer();
        DataContext = viewModel;

        recordingOverlayPresenter = new RecordingOverlayPresenter();
        viewModel.RecordingOverlayStateChanged += OnRecordingOverlayStateChanged;
        recordingOverlayPresenter.CancelRequested += OnRecordingOverlayCancelRequested;
        recordingOverlayPresenter.StopRequested += OnRecordingOverlayStopRequested;
        recordingOverlayPresenter.TeamsWindowCaptureToggleRequested += OnTeamsWindowCaptureToggleRequested;
        recordingOverlayPresenter.TeamsWindowCaptureTargetRequested += OnTeamsWindowCaptureTargetRequested;
        recordingOverlayPresenter.TeamsWindowCaptureRefreshRequested += OnTeamsWindowCaptureRefreshRequested;
        Loaded += OnLoaded;
    }

    public async Task ShutdownAsync()
    {
        if (isShutdown)
        {
            return;
        }

        isShutdown = true;
        viewModel.RecordingOverlayStateChanged -= OnRecordingOverlayStateChanged;
        recordingOverlayPresenter.CancelRequested -= OnRecordingOverlayCancelRequested;
        recordingOverlayPresenter.StopRequested -= OnRecordingOverlayStopRequested;
        recordingOverlayPresenter.TeamsWindowCaptureToggleRequested -= OnTeamsWindowCaptureToggleRequested;
        recordingOverlayPresenter.TeamsWindowCaptureTargetRequested -= OnTeamsWindowCaptureTargetRequested;
        recordingOverlayPresenter.TeamsWindowCaptureRefreshRequested -= OnTeamsWindowCaptureRefreshRequested;
        recordingOverlayPresenter.Hide();
        await viewModel.ShutdownAsync();
        recordingOverlayPresenter.Dispose();
    }

    internal RecorderCrashContext CaptureCrashContext() => viewModel.CaptureCrashContext();

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        Loaded -= OnLoaded;
        await viewModel.InitializeAsync();
    }

    private void OnNavigationSelectionChanged(
        NavigationView sender,
        NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItemContainer?.Tag is string workspace)
        {
            ShowWorkspace(workspace);
        }
    }

    private void ShowWorkspace(string workspace)
    {
        RecordWorkspace.Visibility = workspace == "Record" ? Visibility.Visible : Visibility.Collapsed;
        RecordingsWorkspace.Visibility = workspace == "Recordings" ? Visibility.Visible : Visibility.Collapsed;
        AiWorkspace.Visibility = workspace == "AI" ? Visibility.Visible : Visibility.Collapsed;
        SettingsWorkspace.Visibility = workspace == "Settings" ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnRecordingOverlayStateChanged(object? sender, RecordingOverlayState state)
    {
        if (isShutdown)
        {
            return;
        }

        if (state.IsTeamsAutomaticStartCountdown && state.CountdownSeconds is { } seconds)
        {
            recordingOverlayPresenter.ShowCountdown(seconds);
        }
        else if (state.IsFinalizing && recordingOverlayPresenter is IRecordingOverlayFinalizationPresenter finalizationPresenter)
        {
            finalizationPresenter.ShowFinalizing("正在安全寫入錄音與復原資訊；完成後會自動關閉。");
        }
        else if (state.IsRecording)
        {
            if (recordingOverlayPresenter is RecordingOverlayPresenter livePresenter)
            {
                livePresenter.ShowRecording(
                    viewModel.ActiveRecordingOverlayKind ?? RecordingOverlayRecordingKind.Manual,
                    state.CanToggleTeamsWindowCapture,
                    state.IsTeamsWindowCaptureEnabled,
                    state.TeamsWindowCaptureStatus,
                    state.Elapsed,
                    state.SystemAudioStatus,
                    state.MicrophoneStatus,
                    state.IsRecorderMicrophoneMuted,
                    state.SystemAudioLevelPercent,
                    state.MicrophoneLevelPercent,
                    state.IsVirtualMicrophoneReady,
                    state.VirtualMicrophoneStatus,
                    state.TeamsWindowChoices,
                    state.SelectedTeamsWindow);
            }
            else
            {
                recordingOverlayPresenter.ShowRecording(
                    viewModel.ActiveRecordingOverlayKind ?? RecordingOverlayRecordingKind.Manual,
                    state.CanToggleTeamsWindowCapture,
                    state.IsTeamsWindowCaptureEnabled,
                    state.TeamsWindowCaptureStatus);
            }
        }
        else
        {
            recordingOverlayPresenter.Hide();
        }
    }

    private void OnRecordingOverlayCancelRequested(object? sender, EventArgs args)
    {
        if (viewModel.CancelTeamsAutomaticRecordingStartCommand.CanExecute(null))
        {
            viewModel.CancelTeamsAutomaticRecordingStartCommand.Execute(null);
        }
    }

    private void OnRecordingOverlayStopRequested(object? sender, EventArgs args)
    {
        if (viewModel.StopRecordingFromOverlayCommand.CanExecute(null))
        {
            viewModel.StopRecordingFromOverlayCommand.Execute(null);
        }
    }

    private async void OnTeamsWindowCaptureToggleRequested(
        object? sender,
        TeamsWindowCaptureToggleRequestedEventArgs args)
    {
        if (!isShutdown)
        {
            await viewModel.SetTeamsWindowCaptureDuringRecordingAsync(args.Enabled);
        }
    }

    private async void OnTeamsWindowCaptureTargetRequested(
        object? sender,
        TeamsWindowCaptureTargetRequestedEventArgs args)
    {
        if (!isShutdown)
        {
            await viewModel.SetTeamsWindowCaptureTargetDuringRecordingAsync(args.Target);
        }
    }

    private async void OnTeamsWindowCaptureRefreshRequested(object? sender, EventArgs args)
    {
        if (!isShutdown)
        {
            await viewModel.RefreshTeamsWindowsFromOverlayAsync();
        }
    }

}
