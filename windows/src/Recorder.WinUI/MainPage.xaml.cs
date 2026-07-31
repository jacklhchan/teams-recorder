using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TeamsRecorder.Windows.WinUI;

public sealed partial class MainPage : Page
{
    private readonly RecordingViewModel viewModel;
    private readonly IRecordingOverlayPresenter recordingOverlayPresenter;
    private bool isShutdown;

    public MainPage()
    {
        InitializeComponent();
        viewModel = new RecordingViewModel();
        recordingOverlayPresenter = new RecordingOverlayPresenter();
        viewModel.RecordingOverlayStateChanged += OnRecordingOverlayStateChanged;
        recordingOverlayPresenter.CancelRequested += OnRecordingOverlayCancelRequested;
        recordingOverlayPresenter.StopRequested += OnRecordingOverlayStopRequested;
        viewModel.InitializePlayer();
        DataContext = viewModel;
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
        recordingOverlayPresenter.Hide();
        await viewModel.ShutdownAsync();
        recordingOverlayPresenter.Dispose();
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        Loaded -= OnLoaded;
        await viewModel.InitializeAsync();
    }

    private void OnGoToRecordingSetupClick(object sender, RoutedEventArgs args) =>
        RecordingSetupSection.StartBringIntoView();

    private void OnGoToLibraryClick(object sender, RoutedEventArgs args) =>
        LibrarySection.StartBringIntoView();

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
        else if (state.IsRecording)
        {
            recordingOverlayPresenter.ShowRecording(
                viewModel.ActiveRecordingOverlayKind ?? RecordingOverlayRecordingKind.Manual);
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
}
