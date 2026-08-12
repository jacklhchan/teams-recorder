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
    string? TeamsWindowCaptureStatus = null,
    bool IsFinalizing = false,
    TimeSpan? Elapsed = null,
    RecordingOverlayInputStatus SystemAudioStatus = RecordingOverlayInputStatus.Signal,
    RecordingOverlayInputStatus MicrophoneStatus = RecordingOverlayInputStatus.Quiet,
    bool IsRecorderMicrophoneMuted = false,
    double SystemAudioLevelPercent = 0,
    double MicrophoneLevelPercent = 0,
    bool IsVirtualMicrophoneReady = false,
    string? VirtualMicrophoneStatus = null);

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
    Finalizing,
}

/// <summary>Privacy-safe health projection for one captured audio source.</summary>
public enum RecordingOverlayInputStatus
{
    Signal,
    Quiet,
    Muted,
    Disconnected,
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
    string? TeamsWindowCaptureStatus = null,
    TimeSpan? Elapsed = null,
    RecordingOverlayInputStatus SystemAudioStatus = RecordingOverlayInputStatus.Signal,
    RecordingOverlayInputStatus MicrophoneStatus = RecordingOverlayInputStatus.Quiet,
    bool IsRecorderMicrophoneMuted = false,
    double SystemAudioLevelPercent = 0,
    double MicrophoneLevelPercent = 0,
    bool IsVirtualMicrophoneReady = false,
    string? VirtualMicrophoneStatus = null,
    string? FinalizingStatus = null)
{
    public static RecordingOverlayPresentation Countdown(int remainingSeconds) =>
        new(RecordingOverlayMode.Countdown, Math.Max(0, remainingSeconds));

    public static RecordingOverlayPresentation Recording(
        RecordingOverlayRecordingKind kind,
        bool canToggleTeamsWindowCapture = false,
        bool isTeamsWindowCaptureEnabled = false,
        string? teamsWindowCaptureStatus = null) =>
        new(
            RecordingOverlayMode.Recording,
            RecordingKind: kind,
            CanToggleTeamsWindowCapture: canToggleTeamsWindowCapture,
            IsTeamsWindowCaptureEnabled: isTeamsWindowCaptureEnabled,
            TeamsWindowCaptureStatus: teamsWindowCaptureStatus);

    public static RecordingOverlayPresentation Finalizing(string? status = null) =>
        new(RecordingOverlayMode.Finalizing, FinalizingStatus: status);
}

/// <summary>
/// Requests an exact Teams-window target transition. The overlay never owns
/// capture: a consumer must route this request to the application lifecycle,
/// which keeps one A/V MP4 timeline and uses privacy-black frames for gaps.
/// </summary>
public sealed class TeamsWindowCaptureToggleRequestedEventArgs(bool enabled) : EventArgs
{
    public bool Enabled { get; } = enabled;
}

/// <summary>
/// Requests a Recorder-local microphone mute transition. This never reads or
/// changes the Teams mute state.
/// </summary>
public sealed class RecorderMicrophoneMuteToggleRequestedEventArgs(bool muted) : EventArgs
{
    public bool Muted { get; } = muted;
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

    event EventHandler<RecorderMicrophoneMuteToggleRequestedEventArgs>? RecorderMicrophoneMuteToggleRequested;

    /// <summary>Shows the Teams automatic-recording cancellation countdown.</summary>
    void ShowCountdown(int remainingSeconds);

    /// <summary>Shows the recording state after any source successfully starts.</summary>
    void ShowRecording(RecordingOverlayRecordingKind kind);

    /// <summary>
    /// Shows recording with the optional exact-Teams-window capture control.
    /// The control changes the target of the current A/V timeline; it does not
    /// create a second recording or separate video artifact.
    /// </summary>
    void ShowRecording(
        RecordingOverlayRecordingKind kind,
        bool canToggleTeamsWindowCapture,
        bool isTeamsWindowCaptureEnabled,
        string? teamsWindowCaptureStatus);

    void Hide();
}

/// <summary>
/// Optional safe-write capability, separate from the original presenter
/// contract so existing implementations remain source-compatible.
/// </summary>
public interface IRecordingOverlayFinalizationPresenter
{
    void ShowFinalizing(string? status = null);
}

/// <summary>
/// Reuses one overlay window for the whole application lifetime. Construct and
/// use this presenter from the WinUI UI thread; later updates may come from a
/// worker thread and are marshalled back to that UI thread.
/// </summary>
public sealed class RecordingOverlayPresenter : IRecordingOverlayPresenter, IRecordingOverlayFinalizationPresenter
{
    private readonly RecordingOverlayWindow window;
    private bool disposed;

    public RecordingOverlayPresenter()
    {
        window = new RecordingOverlayWindow();
        window.CancelRequested += (_, _) => CancelRequested?.Invoke(this, EventArgs.Empty);
        window.StopRequested += (_, _) => StopRequested?.Invoke(this, EventArgs.Empty);
        window.TeamsWindowCaptureToggleRequested += (_, args) =>
            TeamsWindowCaptureToggleRequested?.Invoke(this, args);
        window.RecorderMicrophoneMuteToggleRequested += (_, args) =>
            RecorderMicrophoneMuteToggleRequested?.Invoke(this, args);
    }

    public event EventHandler? CancelRequested;

    public event EventHandler? StopRequested;

    public event EventHandler<TeamsWindowCaptureToggleRequestedEventArgs>? TeamsWindowCaptureToggleRequested;

    public event EventHandler<RecorderMicrophoneMuteToggleRequestedEventArgs>? RecorderMicrophoneMuteToggleRequested;

    public void ShowCountdown(int remainingSeconds) =>
        Update(RecordingOverlayPresentation.Countdown(remainingSeconds));

    public void ShowRecording(RecordingOverlayRecordingKind kind) =>
        Update(RecordingOverlayPresentation.Recording(kind));

    public void ShowRecording(
        RecordingOverlayRecordingKind kind,
        bool canToggleTeamsWindowCapture,
        bool isTeamsWindowCaptureEnabled,
        string? teamsWindowCaptureStatus) =>
        Update(RecordingOverlayPresentation.Recording(
            kind,
            canToggleTeamsWindowCapture,
            isTeamsWindowCaptureEnabled,
            teamsWindowCaptureStatus));

    /// <summary>Projects live source health into the recording controller.</summary>
    public void ShowRecording(
        RecordingOverlayRecordingKind kind,
        bool canToggleTeamsWindowCapture,
        bool isTeamsWindowCaptureEnabled,
        string? teamsWindowCaptureStatus,
        TimeSpan? elapsed,
        RecordingOverlayInputStatus systemAudioStatus,
        RecordingOverlayInputStatus microphoneStatus,
        bool isRecorderMicrophoneMuted,
        double systemAudioLevelPercent,
        double microphoneLevelPercent,
        bool isVirtualMicrophoneReady,
        string? virtualMicrophoneStatus) =>
        Update(RecordingOverlayPresentation.Recording(
            kind,
            canToggleTeamsWindowCapture,
            isTeamsWindowCaptureEnabled,
            teamsWindowCaptureStatus) with
        {
            Elapsed = elapsed,
            SystemAudioStatus = systemAudioStatus,
            MicrophoneStatus = microphoneStatus,
            IsRecorderMicrophoneMuted = isRecorderMicrophoneMuted,
            SystemAudioLevelPercent = Math.Clamp(systemAudioLevelPercent, 0, 100),
            MicrophoneLevelPercent = Math.Clamp(microphoneLevelPercent, 0, 100),
            IsVirtualMicrophoneReady = isVirtualMicrophoneReady,
            VirtualMicrophoneStatus = virtualMicrophoneStatus,
        });

    public void ShowFinalizing(string? status = null) =>
        Update(RecordingOverlayPresentation.Finalizing(status));

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
