using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Narrow host boundary for the existing automatic-recording reducer.  It lets
/// the local detector replace the retired Teams WebSocket without coupling this
/// layer to a view model or to WebSocket/token types.
/// </summary>
public interface ITeamsMeetingPresenceSink
{
    Task SetMeetingPresenceAsync(bool isInMeeting, CancellationToken cancellationToken = default);
}

public sealed class TeamsAutomaticRecordingPresenceSink : ITeamsMeetingPresenceSink
{
    private readonly TeamsAutomaticRecordingController controller;

    public TeamsAutomaticRecordingPresenceSink(TeamsAutomaticRecordingController controller) =>
        this.controller = controller ?? throw new ArgumentNullException(nameof(controller));

    public Task SetMeetingPresenceAsync(bool isInMeeting, CancellationToken cancellationToken = default) =>
        controller.SetMeetingPresenceAsync(isInMeeting, cancellationToken);
}

/// <summary>
/// Privacy-safe UI projection for local Teams integration.  It has no title,
/// HWND, PID, path, account, token, raw UIA identifier, or exception text.
/// </summary>
public sealed record TeamsLocalIntegrationSnapshot(
    TeamsLocalMeetingDetectionSnapshot Meeting,
    TeamsLocalMuteState MuteState,
    TeamsUiAutomationFailure MuteFailure,
    bool IsRunning)
{
    public static TeamsLocalIntegrationSnapshot Initial { get; } = new(
        TeamsLocalMeetingDetectionSnapshot.Initial,
        TeamsLocalMuteState.Unknown,
        TeamsUiAutomationFailure.None,
        false);
}

/// <summary>
/// Replaces Teams Third-party-App-API pairing/WebSocket state with local,
/// identity-validated window detection and strict UI Automation.  It has no
/// credential storage or network transport. Teams mute observations are status
/// only: they never read, guess, or change the Recorder microphone contribution.
/// </summary>
public sealed class TeamsLocalIntegrationCoordinator : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly TeamsLocalMeetingMonitor monitor;
    private readonly ITeamsLocalMuteController muteController;
    private readonly ITeamsMeetingPresenceSink meetingPresence;
    private TeamsLocalIntegrationSnapshot snapshot = TeamsLocalIntegrationSnapshot.Initial;
    private bool started;
    private bool disposed;
    private long presenceGeneration;

    public TeamsLocalIntegrationCoordinator(
        TeamsLocalMeetingMonitor monitor,
        ITeamsLocalMuteController muteController,
        ITeamsMeetingPresenceSink meetingPresence)
    {
        this.monitor = monitor ?? throw new ArgumentNullException(nameof(monitor));
        this.muteController = muteController ?? throw new ArgumentNullException(nameof(muteController));
        this.meetingPresence = meetingPresence ?? throw new ArgumentNullException(nameof(meetingPresence));
    }

    public event EventHandler<TeamsLocalIntegrationSnapshot>? SnapshotChanged;

    public TeamsLocalIntegrationSnapshot Snapshot
    {
        get { lock (gate) return snapshot; }
    }

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        lock (gate)
        {
            if (started)
            {
                return;
            }
            started = true;
            monitor.DetectionChanged += OnDetectionChanged;
            PublishLocked(snapshot with { IsRunning = true, Meeting = monitor.Snapshot });
        }

        try
        {
            await monitor.StartAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            lock (gate)
            {
                monitor.DetectionChanged -= OnDetectionChanged;
                started = false;
                PublishLocked(snapshot with { IsRunning = false });
            }
            throw;
        }
    }

    /// <summary>
    /// Reads Teams' current mute state for status only. Recorder microphone
    /// state remains independently user-controlled.
    /// </summary>
    public Task<TeamsUiAutomationMuteResult> RefreshMuteAsync(CancellationToken cancellationToken = default) =>
        ApplyMuteOperationAsync(muted: null, cancellationToken);

    /// <summary>
    /// Compatibility-only Teams UIA operation. Its result is never routed into
    /// Recorder microphone state.
    /// </summary>
    public Task<TeamsUiAutomationMuteResult> SetMutedAsync(bool muted, CancellationToken cancellationToken = default) =>
        ApplyMuteOperationAsync(muted, cancellationToken);

    private Task<TeamsUiAutomationMuteResult> ApplyMuteOperationAsync(
        bool? muted,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ThrowIfDisposed();

        TeamsWindowIdentity? identity;
        lock (gate)
        {
            identity = started ? monitor.ActiveIdentity : null;
        }

        if (identity is null)
        {
            return Task.FromResult(PublishMuteResult(
                TeamsUiAutomationMuteResult.Unknown(TeamsUiAutomationFailure.WindowIdentityInvalid)));
        }

        var result = muted is { } desired
            ? muteController.SetMuted(identity.Value, desired)
            : muteController.Read(identity.Value);

        return Task.FromResult(PublishMuteResult(result));
    }

    private TeamsUiAutomationMuteResult PublishMuteResult(
        TeamsUiAutomationMuteResult result)
    {
        lock (gate)
        {
            PublishLocked(snapshot with
            {
                MuteState = result.State,
                MuteFailure = result.Failure,
            });
        }
        return result;
    }

    private void OnDetectionChanged(object? sender, TeamsLocalMeetingDetectionUpdate update)
    {
        if (!IsRunning())
        {
            return;
        }

        lock (gate)
        {
            PublishLocked(snapshot with { Meeting = update.Snapshot });
        }

        if (update.MeetingPresenceChanged is { } present)
        {
            var expectedGeneration = Interlocked.Increment(ref presenceGeneration);
            _ = PropagateMeetingPresenceAsync(present, expectedGeneration);
        }
    }

    private async Task PropagateMeetingPresenceAsync(bool present, long expectedGeneration)
    {
        try
        {
            // The controller serializes its reducer itself.  A generation check
            // before delivery prevents a stale queued "in meeting" from
            // overriding a newer identity-loss/stop signal.
            if (!IsRunning() || Volatile.Read(ref presenceGeneration) != expectedGeneration)
            {
                return;
            }
            await meetingPresence.SetMeetingPresenceAsync(present).ConfigureAwait(false);
        }
        catch (ObjectDisposedException)
        {
            // Shutdown of the host reducer is an expected race.
        }
        catch (OperationCanceledException)
        {
        }
        catch
        {
            // Do not surface arbitrary host errors in this privacy-safe layer.
            // The host owns its recorder error projection.
        }
    }

    public async Task StopAsync()
    {
        bool shouldNotifyEnd;
        lock (gate)
        {
            if (!started)
            {
                return;
            }

            shouldNotifyEnd = snapshot.Meeting.IsMeetingPresent;
            started = false;
            Interlocked.Increment(ref presenceGeneration);
            monitor.DetectionChanged -= OnDetectionChanged;
            PublishLocked(snapshot with
            {
                IsRunning = false,
                Meeting = TeamsLocalMeetingDetectionSnapshot.Initial,
                MuteState = TeamsLocalMuteState.Unknown,
                MuteFailure = TeamsUiAutomationFailure.None,
            });
        }

        await monitor.StopAsync().ConfigureAwait(false);
        if (shouldNotifyEnd)
        {
            try { await meetingPresence.SetMeetingPresenceAsync(false).ConfigureAwait(false); }
            catch (ObjectDisposedException) { }
            catch (OperationCanceledException) { }
        }
    }

    private bool IsRunning()
    {
        lock (gate) return started && !disposed;
    }

    private void PublishLocked(TeamsLocalIntegrationSnapshot next)
    {
        if (snapshot == next)
        {
            return;
        }

        snapshot = next;
        // Handler calls are deliberately outside the lock.  Capture it here and
        // post after releasing through the local helper in each public path.
        var handler = SnapshotChanged;
        if (handler is not null)
        {
            // The snapshot has no sensitive payload; dispatch asynchronously to
            // avoid reentrancy into monitor/UIA while a state lock is held.
            _ = Task.Run(() => handler(this, next));
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        await StopAsync().ConfigureAwait(false);
        await monitor.DisposeAsync().ConfigureAwait(false);
    }

    private void ThrowIfDisposed()
    {
        if (disposed)
        {
            throw new ObjectDisposedException(nameof(TeamsLocalIntegrationCoordinator));
        }
    }
}
