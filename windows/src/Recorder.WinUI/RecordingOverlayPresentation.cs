namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// A neutral state contract which a view-model or an automatic-recording
/// adapter can publish without giving the overlay ownership of recording.
/// </summary>
public sealed record RecordingOverlayState(
    bool IsVisible,
    bool IsRecording,
    bool IsTeamsAutomaticStartCountdown,
    int? CountdownSeconds,
    bool CanCancelAutomaticStart,
    bool CanStopRecording,
    bool CanToggleTeamsWindowCapture = false,
    bool IsTeamsWindowCaptureEnabled = false,
    string? TeamsWindowCaptureStatus = null);

/// <summary>
/// Optional adapter boundary for a ViewModel. The overlay itself needs no
/// knowledge of commands, recording services, or Teams implementation details.
/// </summary>
public interface IRecordingOverlayStateSource
{
    RecordingOverlayState RecordingOverlayState { get; }

    event EventHandler<RecordingOverlayState>? RecordingOverlayStateChanged;
}

/// <summary>
/// The small set of states which can be rendered by the recording overlay.
/// This is deliberately independent from RecordingViewModel and the automatic
/// recording controller so either caller can project its own state into it.
/// </summary>
public enum RecordingOverlayMode
{
    Countdown,
    Recording,
}

/// <summary>
/// The successful-start source supplied by the integration layer. The current
/// overlay intentionally has the same recording treatment for each source,
/// while retaining this value for future source-specific copy or telemetry.
/// </summary>
public enum RecordingOverlayRecordingKind
{
    Manual,
    Test,
    TeamsAutomatic,
}

/// <summary>
/// A display-only snapshot for <see cref="RecordingOverlayWindow"/>.
/// </summary>
public sealed record RecordingOverlayPresentation(
    RecordingOverlayMode Mode,
    int RemainingSeconds = 0,
    RecordingOverlayRecordingKind? RecordingKind = null,
    bool CanToggleTeamsWindowCapture = false,
    bool IsTeamsWindowCaptureEnabled = false,
    string? TeamsWindowCaptureStatus = null)
{
    public static RecordingOverlayPresentation Countdown(int remainingSeconds) =>
        new(RecordingOverlayMode.Countdown, Math.Max(0, remainingSeconds));

    public static RecordingOverlayPresentation Recording(
        RecordingOverlayRecordingKind kind,
        bool canToggleTeamsWindowCapture = false,
        bool isTeamsWindowCaptureEnabled = false,
        string? teamsWindowCaptureStatus = null) =>
        new(RecordingOverlayMode.Recording, RecordingKind: kind,
            CanToggleTeamsWindowCapture: canToggleTeamsWindowCapture,
            IsTeamsWindowCaptureEnabled: isTeamsWindowCaptureEnabled,
            TeamsWindowCaptureStatus: teamsWindowCaptureStatus);
}

public sealed class TeamsWindowCaptureToggleRequestedEventArgs(bool enabled) : EventArgs
{
    public bool Enabled { get; } = enabled;
}

/// <summary>
/// Presents an auxiliary, non-activating recording window. Consumers subscribe
/// to the events and keep recording ownership in their existing coordinator.
/// </summary>
public interface IRecordingOverlayPresenter : IDisposable
{
    event EventHandler? CancelRequested;

    event EventHandler? StopRequested;

    event EventHandler<TeamsWindowCaptureToggleRequestedEventArgs>? TeamsWindowCaptureToggleRequested;

    /// <summary>Shows the Teams automatic-recording cancellation countdown.</summary>
    void ShowCountdown(int remainingSeconds);

    /// <summary>Shows the recording state after any source successfully starts.</summary>
    void ShowRecording(RecordingOverlayRecordingKind kind, bool canToggleTeamsWindowCapture,
        bool isTeamsWindowCaptureEnabled, string? teamsWindowCaptureStatus);

    void Hide();
}

/// <summary>
/// Reuses one overlay window for the whole application lifetime. Construct and
/// use this presenter from the WinUI UI thread; later updates may come from a
/// worker thread and are marshalled back to that UI thread.
/// </summary>
public sealed class RecordingOverlayPresenter : IRecordingOverlayPresenter
{
    private readonly RecordingOverlayWindow window;
    private bool disposed;

    public RecordingOverlayPresenter()
    {
        window = new RecordingOverlayWindow();
        window.CancelRequested += (_, _) => CancelRequested?.Invoke(this, EventArgs.Empty);
        window.StopRequested += (_, _) => StopRequested?.Invoke(this, EventArgs.Empty);
        window.TeamsWindowCaptureToggleRequested += (_, args) => TeamsWindowCaptureToggleRequested?.Invoke(this, args);
    }

    public event EventHandler? CancelRequested;

    public event EventHandler? StopRequested;

    public event EventHandler<TeamsWindowCaptureToggleRequestedEventArgs>? TeamsWindowCaptureToggleRequested;

    public void ShowCountdown(int remainingSeconds) =>
        Update(RecordingOverlayPresentation.Countdown(remainingSeconds));

    public void ShowRecording(RecordingOverlayRecordingKind kind, bool canToggleTeamsWindowCapture,
        bool isTeamsWindowCaptureEnabled, string? teamsWindowCaptureStatus) =>
        Update(RecordingOverlayPresentation.Recording(kind, canToggleTeamsWindowCapture,
            isTeamsWindowCaptureEnabled, teamsWindowCaptureStatus));

    public void Hide()
    {
        if (disposed)
        {
            return;
        }

        RunOnUiThread(window.HideNonActivating);
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        RunOnUiThread(window.CloseNonActivating);
    }

    private void Update(RecordingOverlayPresentation presentation)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        RunOnUiThread(() =>
        {
            window.ApplyPresentation(presentation);
            window.ShowNonActivating();
        });
    }

    private void RunOnUiThread(Action action)
    {
        if (window.DispatcherQueue.HasThreadAccess)
        {
            action();
            return;
        }

        _ = window.DispatcherQueue.TryEnqueue(() => action());
    }
}
