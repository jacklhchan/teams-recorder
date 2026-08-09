using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TeamsRecorder.Windows.Application.Diagnostics;

namespace TeamsRecorder.Windows.WinUI;

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
        recordingOverlayPresenter = new RecordingOverlayPresenter();
        viewModel.RecordingOverlayStateChanged += OnRecordingOverlayStateChanged;
        recordingOverlayPresenter.CancelRequested += OnRecordingOverlayCancelRequested;
        recordingOverlayPresenter.StopRequested += OnRecordingOverlayStopRequested;
        viewModel.InitializePlayer();
        PlaybackVideoStage.SetMediaPlayer(viewModel.PlaybackMediaPlayer!);
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

    private void OnNavigationSelectionChanged(
        NavigationView sender,
        NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItemContainer?.Tag is string workspace)
        {
            ShowWorkspace(workspace);
        }
    }

    private void OnLibrarySearchTextChanged(object sender, TextChangedEventArgs args)
    {
        // TextBox bindings can otherwise wait for focus to move before they
        // commit.  The library's bounded local index is safe to filter on each
        // keystroke and never sends transcript content anywhere.
        if (sender is TextBox searchBox && DataContext is RecordingViewModel model)
        {
            model.LibrarySearchText = searchBox.Text;
        }
    }

    internal RecorderCrashContext CaptureCrashContext() => viewModel.CaptureCrashContext();

    private void ShowWorkspace(string workspace)
    {
        RecordWorkspace.Visibility = workspace == "Record" ? Visibility.Visible : Visibility.Collapsed;
        RecordingsWorkspace.Visibility = workspace == "Recordings" ? Visibility.Visible : Visibility.Collapsed;
        SettingsWorkspace.Visibility = workspace == "Settings" ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void OnSaveOpenAiProviderSettingsClick(object sender, RoutedEventArgs args)
    {
        var replacementKey = OpenAiApiKeyPasswordBox.Password;
        try
        {
            await viewModel.SaveOpenAiProviderSettingsAsync(replacementKey);
        }
        finally
        {
            // Never retain the password-box value after the save attempt. An empty value
            // means "keep the existing key"; deletion has its own explicit action.
            OpenAiApiKeyPasswordBox.Password = string.Empty;
        }
    }

    private async void OnClearOpenAiApiKeyClick(object sender, RoutedEventArgs args)
    {
        if (!await ConfirmAsync(
                "移除本機 API Key",
                "這會移除目前 Windows 使用者的本機加密 API Key。供應商設定會保留，但之後若供應商需要驗證，請重新輸入金鑰。",
                "移除"))
        {
            return;
        }

        await viewModel.ClearOpenAiApiKeyAsync();
        OpenAiApiKeyPasswordBox.Password = string.Empty;
    }

    private async void OnStartOpenAiTranscriptionClick(object sender, RoutedEventArgs args)
    {
        if (!await ConfirmAsync(
                "確認上傳音訊",
                "將把目前選取、已完成的 M4A 錄音傳送至您設定的 OpenAI 相容 ASR 供應商。按「繼續」才會開始；錄音不會在背景自動上傳。",
                "繼續"))
        {
            return;
        }

        await viewModel.StartOpenAiTranscriptionAsync();
    }

    private async void OnGenerateOpenAiSummaryClick(object sender, RoutedEventArgs args)
    {
        if (!await ConfirmAsync(
                "確認上傳逐字稿",
                "將把目前選取錄音的已完成逐字稿文字傳送至您設定的 OpenAI 相容 LLM 供應商，以產生摘要。音訊不會再次上傳。",
                "繼續"))
        {
            return;
        }

        await viewModel.GenerateOpenAiSummaryAsync();
    }

    private async Task<bool> ConfirmAsync(string title, string message, string primaryButtonText)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = title,
            Content = message,
            PrimaryButtonText = primaryButtonText,
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
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
