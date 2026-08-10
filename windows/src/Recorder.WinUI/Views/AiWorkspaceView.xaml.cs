using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TeamsRecorder.Windows.WinUI.Views;

/// <summary>
/// AI workspace presentation. It deliberately keeps consent at the UI edge:
/// the view model receives an explicit opt-in only after the user confirms.
/// </summary>
public sealed partial class AiWorkspaceView : UserControl
{
    public AiWorkspaceView()
    {
        InitializeComponent();
    }

    private async void OnStartTranscriptionClick(object sender, RoutedEventArgs args)
    {
        if (DataContext is not RecordingViewModel viewModel || !viewModel.CanStartOpenAiTranscription)
        {
            return;
        }

        if (!await ConfirmAsync(
                "確認上傳音訊",
                "將把目前選取、已完成的錄音傳送至您設定的 OpenAI 相容 ASR 供應商。按下「繼續」才會開始；錄音不會在背景自動上傳。",
                "繼續"))
        {
            return;
        }

        await viewModel.StartOpenAiTranscriptionAsync();
    }

    private async void OnGenerateSummaryClick(object sender, RoutedEventArgs args)
    {
        if (DataContext is not RecordingViewModel viewModel || !viewModel.CanGenerateOpenAiSummary)
        {
            return;
        }

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
        if (XamlRoot is null)
        {
            return false;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = title,
            Content = message,
            PrimaryButtonText = primaryButtonText,
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };

        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }
}
