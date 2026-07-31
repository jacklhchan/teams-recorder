namespace TeamsRecorder.Windows.Application;

public enum TeamsMuteSyncStatus { Disabled, WaitingForTeamsApi, WaitingForMeeting, WaitingForPairingApproval, Ready, InMeeting, Failed }

public sealed record TeamsMuteSyncSnapshot(
    TeamsMuteSyncStatus Status,
    TeamsMeetingState? LastMeetingState,
    string? Detail,
    bool IsPairingAuthenticated = false,
    bool IsMicrophoneRoutingEngaged = false,
    bool IsPairingKnown = false)
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
/// Applies authenticated Teams mute updates to recorder audio without ever controlling Teams.
/// A single initial unmuted snapshot never opens the recorder microphone: routing only engages
/// after Teams reports a muted state, so an implementation that fails to push later updates cannot
/// turn a locally muted recording source back on. Once routing has engaged, lost trust fails closed.
/// </summary>
public sealed class TeamsMuteSyncCoordinator : IDisposable
{
    private readonly object gate = new();
    private readonly ITeamsThirdPartyApiClient client;
    private readonly IRecorderMicrophoneMuteSink microphone;
    private TeamsMuteSyncSnapshot snapshot = TeamsMuteSyncSnapshot.Initial;
    private bool enabled;
    private bool microphoneRoutingEngaged;
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
            if (!value && microphoneRoutingEngaged)
            {
                microphone.SetMuted(false);
                microphoneRoutingEngaged = false;
            }
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
                case TeamsThirdPartyApiEvent.MeetingUpdate(var update, var isPairingAuthenticated):
                    if (!isPairingAuthenticated)
                    {
                        FailClosedForLostTrustLocked();
                        SetSnapshotLocked(new TeamsMuteSyncSnapshot(
                            update.CanPair ? TeamsMuteSyncStatus.WaitingForPairingApproval : TeamsMuteSyncStatus.WaitingForMeeting,
                            null,
                            null,
                            false,
                            microphoneRoutingEngaged));
                    }
                    else if (update.State is { } state)
                    {
                        ApplyMutedStateIfSafeLocked(state);
                        SetSnapshotLocked(snapshot with
                        {
                            LastMeetingState = state,
                            Status = state.IsInMeeting ? TeamsMuteSyncStatus.InMeeting : TeamsMuteSyncStatus.Ready,
                            Detail = null,
                            IsPairingAuthenticated = true,
                            IsMicrophoneRoutingEngaged = microphoneRoutingEngaged,
                            IsPairingKnown = true,
                        });
                        MeetingPresenceChanged?.Invoke(this, state.IsInMeeting);
                    }
                    else
                    {
                        FailClosedForLostTrustLocked();
                        SetSnapshotLocked(new TeamsMuteSyncSnapshot(
                            TeamsMuteSyncStatus.WaitingForMeeting,
                            null,
                            null,
                            true,
                            microphoneRoutingEngaged,
                            true));
                    }
                    break;
                case TeamsThirdPartyApiEvent.Error(_, var message) when IsAlreadyPairedResponse(message):
                    // A pairing retry may race with an existing Teams credential.  This is not
                    // a loss of trust: keep any authenticated meeting snapshot and otherwise
                    // wait for the authenticated connection to supply its first meeting update.
                    if (snapshot.IsPairingAuthenticated)
                    {
                        SetSnapshotLocked(snapshot with
                        {
                            Status = snapshot.LastMeetingState?.IsInMeeting == true
                                ? TeamsMuteSyncStatus.InMeeting
                                : TeamsMuteSyncStatus.Ready,
                            Detail = null,
                        });
                    }
                    else
                    {
                        SetSnapshotLocked(snapshot with
                        {
                            Status = TeamsMuteSyncStatus.WaitingForMeeting,
                            Detail = null,
                            IsPairingKnown = true,
                        });
                    }
                    break;
                case TeamsThirdPartyApiEvent.Error(_, var message):
                    FailClosedForLostTrustLocked();
                    SetSnapshotLocked(new TeamsMuteSyncSnapshot(TeamsMuteSyncStatus.Failed, null, message, false, microphoneRoutingEngaged));
                    break;
            }
        }
    }

    private void OnConnectionChanged(object? sender, string? error)
    {
        lock (gate)
        {
            if (!enabled) return;
            FailClosedForLostTrustLocked();
            SetSnapshotLocked(new TeamsMuteSyncSnapshot(TeamsMuteSyncStatus.WaitingForTeamsApi, null, error, false, microphoneRoutingEngaged));
        }
    }

    private void ApplyMutedStateIfSafeLocked(TeamsMeetingState state)
    {
        var previous = snapshot.LastMeetingState;
        if (!state.IsInMeeting)
        {
            if (microphoneRoutingEngaged)
            {
                microphone.SetMuted(false);
                microphoneRoutingEngaged = false;
            }
            return;
        }

        if (state.IsMuted)
        {
            microphone.SetMuted(true);
            microphoneRoutingEngaged = true;
            return;
        }

        // Do not unmute from a connection's initial snapshot. A later unmuted state is useful
        // only after this connection has first established that the muted state was delivered.
        if (microphoneRoutingEngaged && previous is { IsInMeeting: true, IsMuted: true })
            microphone.SetMuted(false);
    }

    private void FailClosedForLostTrustLocked()
    {
        var wasTrustedMeeting = snapshot.IsPairingAuthenticated && snapshot.LastMeetingState is { IsInMeeting: true };
        if (microphoneRoutingEngaged) microphone.SetMuted(true);
        if (wasTrustedMeeting) MeetingPresenceChanged?.Invoke(this, false);
    }

    private static bool IsAlreadyPairedResponse(string message) =>
        message.Contains("already paired", StringComparison.OrdinalIgnoreCase);

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
