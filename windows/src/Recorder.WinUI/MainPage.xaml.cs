using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Presents the first usable system-loopback capture flow.
/// </summary>
public sealed partial class MainPage : Page
{
    private readonly RecordingViewModel viewModel;

    public MainPage()
    {
        InitializeComponent();
        viewModel = new RecordingViewModel();
        DataContext = viewModel;
        Loaded += OnLoaded;
    }

    public Task ShutdownAsync() => viewModel.ShutdownAsync();

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        Loaded -= OnLoaded;
        await viewModel.InitializeAsync();
    }
}
