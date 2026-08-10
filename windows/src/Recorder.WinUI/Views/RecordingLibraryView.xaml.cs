using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TeamsRecorder.Windows.WinUI.Views;

/// <summary>
/// The recordings library and selected-item playback surface. Its DataContext
/// is inherited from the host and is expected to be a <see cref="RecordingViewModel"/>.
/// </summary>
public sealed partial class RecordingLibraryView : UserControl
{
    public RecordingLibraryView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        DataContextChanged += OnDataContextChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs args) => AttachMediaPlayer();

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args) => AttachMediaPlayer();

    private void OnLibrarySearchTextChanged(object sender, TextChangedEventArgs args)
    {
        // Commit on every keystroke so the library's local index filters without
        // requiring the user to move keyboard focus away from the search box.
        if (DataContext is RecordingViewModel viewModel && sender is TextBox searchBox)
        {
            viewModel.LibrarySearchText = searchBox.Text;
        }
    }

    private void AttachMediaPlayer()
    {
        if (DataContext is RecordingViewModel { PlaybackMediaPlayer: { } player })
        {
            PlaybackVideoStage.SetMediaPlayer(player);
        }
    }
}
