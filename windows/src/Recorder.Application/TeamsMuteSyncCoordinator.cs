namespace TeamsRecorder.Windows.Application;

public enum TeamsMuteSyncStatus { Disabled, WaitingForTeamsApi, WaitingForMeeting, WaitingForPairingApproval, Ready, InMeeting, Failed }

public sealed record TeamsMuteSyncSnapshot(TeamsMuteSyncStatus Status, TeamsMeetingState? LastMeetingState, string? Detail)
{
    public static TeamsMuteSyncSnapshot Initial { get; } = new(TeamsMuteSyncStatus.Disabled, null, null);
}

/// <summary>Transport boundary for the local Teams WebSocket. Implementations must never log the pairing token.</summary>
public interface ITeamsThirdPartyApiClient
{
    event EventHandler<TeamsThirdPartyApiEvent>? EventReceived;
    event EventHandler<string?>? ConnectionChanged;
    Task StartAsync(CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);
    Task RequestPairingAsync(CancellationToken cancellationToken = default);
}

/// <summary>Local recorder/virtual-mic mute sink. The value is absolute, never a toggle.</summary>
public interface IRecorderMicrophoneMuteSink { void SetMuted(bool muted); }

/// <summary>
/// Applies authoritative Teams mute notifications to recorder audio. If a previously observed
/// Teams meeting loses its API connection, it fails closed by muting the local microphone until
/// a fresh absolute state is received. It does not mute/unmute Teams itself.
/// </summary>
public sealed class TeamsMuteSyncCoordinator : IDisposable
{
    private readonly object gate = new();
    private readonly ITeamsThirdPartyApiClient client;
    private readonly IRecorderMicrophoneMuteSink microphone;
    private TeamsMuteSyncSnapshot snapshot = TeamsMuteSyncSnapshot.Initial;
    private bool enabled;
    private bool disposed;

    public TeamsMuteSyncCoordinator(ITeamsThirdPartyApiClient client, IRecorderMicrophoneMuteSink microphone)
    {
        this.client = client ?? throw new ArgumentNullException(nameof(client));
        this.microphone = microphone ?? throw new ArgumentNullException(nameof(microphone));
        client.EventReceived += OnApiEvent;
        client.ConnectionChanged += OnConnectionChanged;
    }

    public event EventHandler<TeamsMuteSyncSnapshot>? SnapshotChanged;
    public event EventHandler<bool>? MeetingPresenceChanged;
    public TeamsMuteSyncSnapshot Snapshot { get { lock (gate) return snapshot; } }

    public async Task SetEnabledAsync(bool value, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        lock (gate)
        {
            enabled = value;
            SetSnapshotLocked(value ? snapshot with { Status = TeamsMuteSyncStatus.WaitingForTeamsApi, Detail = null } : TeamsMuteSyncSnapshot.Initial);
        }
        if (value) await client.StartAsync(cancellationToken).ConfigureAwait(false);
        else await client.StopAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task RequestPairingAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        lock (gate)
        {
            if (!enabled)
                throw new InvalidOperationException("Teams mute synchronization must be enabled before pairing.");
        }

        // Do not report an approval request until it was accepted by the active local
        // WebSocket.  This prevents a disconnected UI from implying that Teams saw it.
        await client.RequestPairingAsync(cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            if (enabled)
                SetSnapshotLocked(snapshot with { Status = TeamsMuteSyncStatus.WaitingForPairingApproval, Detail = null });
        }
    }

    private void OnApiEvent(object? sender, TeamsThirdPartyApiEvent @event)
    {
        lock (gate)
        {
            if (!enabled) return;
            switch (@event)
            {
                case TeamsThirdPartyApiEvent.MeetingUpdate(var update):
                    if (update.State is { } state)
                    {
                        if (state.IsInMeeting) microphone.SetMuted(state.IsMuted);
                        SetSnapshotLocked(snapshot with
                        {
                            LastMeetingState = state,
                            Status = state.IsInMeeting ? TeamsMuteSyncStatus.InMeeting : TeamsMuteSyncStatus.Ready,
                            Detail = null,
                        });
                        MeetingPresenceChanged?.Invoke(this, state.IsInMeeting);
                    }
                    else SetSnapshotLocked(snapshot with { Status = update.CanPair ? TeamsMuteSyncStatus.WaitingForPairingApproval : TeamsMuteSyncStatus.WaitingForMeeting });
                    break;
                case TeamsThirdPartyApiEvent.Error(_, var message):
                    SetSnapshotLocked(snapshot with { Status = TeamsMuteSyncStatus.Failed, Detail = message });
                    break;
            }
        }
    }

    private void OnConnectionChanged(object? sender, string? error)
    {
        lock (gate)
        {
            if (!enabled) return;
            if (snapshot.LastMeetingState is { IsInMeeting: true }) microphone.SetMuted(true);
            SetSnapshotLocked(snapshot with { Status = TeamsMuteSyncStatus.WaitingForTeamsApi, Detail = error });
        }
    }

    private void SetSnapshotLocked(TeamsMuteSyncSnapshot value)
    {
        if (snapshot == value) return;
        snapshot = value;
        SnapshotChanged?.Invoke(this, value);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        client.EventReceived -= OnApiEvent;
        client.ConnectionChanged -= OnConnectionChanged;
    }
    private void ThrowIfDisposed() { if (disposed) throw new ObjectDisposedException(nameof(TeamsMuteSyncCoordinator)); }
}
