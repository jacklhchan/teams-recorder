using Microsoft.UI.Xaml.Controls;
using TeamsRecorder.Windows.WinUI;

namespace TeamsRecorder.Windows.WinUI.Views;

/// <summary>
/// Production record-dashboard surface. Its DataContext is supplied by the host
/// and is expected to be the shared <see cref="RecordingViewModel"/> instance.
/// </summary>
public sealed partial class RecordDashboardView : UserControl
{
    public RecordDashboardView()
    {
        InitializeComponent();
    }
}
