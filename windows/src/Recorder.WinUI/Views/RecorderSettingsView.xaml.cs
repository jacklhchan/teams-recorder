using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TeamsRecorder.Windows.WinUI.Views;

/// <summary>
/// Settings surface for the existing recorder view model. The host owns the
/// view model and supplies it as this page's data context.
/// </summary>
public sealed partial class RecorderSettingsView : Page
{
    public RecorderSettingsView()
    {
        InitializeComponent();
    }

    private async void OnSaveOpenAiProviderSettingsClick(object sender, RoutedEventArgs args)
    {
        if (DataContext is not RecordingViewModel viewModel)
        {
            return;
        }

        try
        {
            await viewModel.SaveOpenAiProviderSettingsAsync(OpenAiApiKeyPasswordBox.Password);
        }
        finally
        {
            // An empty value means keep the existing DPAPI-protected key.
            OpenAiApiKeyPasswordBox.Password = string.Empty;
        }
    }

    private async void OnClearOpenAiApiKeyClick(object sender, RoutedEventArgs args)
    {
        if (DataContext is not RecordingViewModel viewModel || Content.XamlRoot is null)
        {
            return;
        }

        var confirmation = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "移除本機 API Key",
            Content = "這會移除目前 Windows 使用者的本機加密 API Key。供應商設定會保留，但之後需要驗證時必須重新輸入金鑰。",
            PrimaryButtonText = "移除",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };

        if (await confirmation.ShowAsync() == ContentDialogResult.Primary)
        {
            await viewModel.ClearOpenAiApiKeyAsync();
            OpenAiApiKeyPasswordBox.Password = string.Empty;
        }
    }
}
