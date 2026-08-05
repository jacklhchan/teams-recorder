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
    TeamsTransportDiagnosticSnapshot TransportSnapshot { get; }
    Task StartAsync(CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);
    Task RefreshStateAsync(CancellationToken cancellationToken = default);
    Task RequestPairingAsync(CancellationToken cancellationToken = default);
    /// <summary>
    /// Removes the locally protected pairing credential and starts a new local Teams API
    /// connection. This does not alter Teams settings or approve a pairing prompt.
    /// </summary>
    Task ResetPairingAsync(CancellationToken cancellationToken = default);
}

/// <summary>Legacy recorder mute sink retained only for source compatibility.</summary>
public interface IRecorderMicrophoneMuteSink { void SetMuted(bool muted); }

/// <summary>
/// Tracks paired Teams meeting evidence only. It does not apply Teams mute state to the
/// recorder: Recorder microphone contribution is controlled solely by local controls.
/// </summary>
public sealed class TeamsMuteSyncCoordinator : IDisposable
{
    private readonly object gate = new();
    private readonly ITeamsThirdPartyApiClient client;
    private TeamsMuteSyncSnapshot snapshot = TeamsMuteSyncSnapshot.Initial;
    private bool pairingRequestPending;
    private long meetingEvidenceRevision;
    private bool enabled;
    private bool disposed;

    public TeamsMuteSyncCoordinator(ITeamsThirdPartyApiClient client, IRecorderMicrophoneMuteSink? legacyMicrophoneSink = null)
    {
        this.client = client ?? throw new ArgumentNullException(nameof(client));
        _ = legacyMicrophoneSink;
        client.EventReceived += OnApiEvent;
        client.ConnectionChanged += OnConnectionChanged;
    }

    public event EventHandler<TeamsMuteSyncSnapshot>? SnapshotChanged;
    public event EventHandler<TeamsMeetingEvidence>? MeetingEvidenceChanged;
    // Retained for source compatibility. It reports only confirmed paired state;
    // transport loss is intentionally conveyed through MeetingEvidenceChanged.
    public event EventHandler<bool>? MeetingPresenceChanged;
    public TeamsMuteSyncSnapshot Snapshot { get { lock (gate) return snapshot; } }

    public async Task SetEnabledAsync(bool value, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        lock (gate)
        {
            enabled = value;
            if (!value) pairingRequestPending = false;
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
            {
                pairingRequestPending = true;
                SetSnapshotLocked(snapshot with { Status = TeamsMuteSyncStatus.WaitingForPairingApproval, Detail = null });
            }
        }
    }

    /// <summary>
    /// Repairs a stale local pairing credential. This only asks the client to begin a fresh
    /// pairing attempt; a healthy state is established solely by a later Teams-issued token and
    /// complete meeting state. Existing recording audio is deliberately untouched.
    /// </summary>
    public async Task ResetPairingAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        lock (gate)
        {
            if (!enabled)
                throw new InvalidOperationException("Teams mute synchronization must be enabled before repairing pairing.");
            pairingRequestPending = false;
            FailClosedForLostTrustLocked();
            SetSnapshotLocked(new TeamsMuteSyncSnapshot(
                TeamsMuteSyncStatus.WaitingForPairingApproval,
                null,
                "Repairing the local Teams pairing credential. Waiting for Teams to issue a new credential and meeting state.",
                false,
                false,
                false));
        }

        await client.ResetPairingAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Requests a fresh meeting snapshot without changing pairing state. Teams may not push
    /// every mute or meeting-end transition on every desktop build, so the host can use this
    /// small refresh while a recording is active.
    /// </summary>
    public async Task RefreshStateAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        lock (gate)
        {
            if (!enabled) return;
        }

        await client.RefreshStateAsync(cancellationToken).ConfigureAwait(false);
    }

    private void OnApiEvent(object? sender, TeamsThirdPartyApiEvent @event)
    {
        lock (gate)
        {
            if (!enabled) return;
            switch (@event)
            {
                case TeamsThirdPartyApiEvent.MeetingUpdate(var update, var hasStoredPairingCredential):
                    // A Teams-issued credential remains authoritative for this local
                    // connection. canPair announces that Teams can offer pairing; it does not
                    // revoke an existing credential. Treating it as revocation prevented
                    // existing users from entering the automatic-recording countdown.
                    if (!hasStoredPairingCredential)
                    {
                        FailClosedForLostTrustLocked();
                        SetSnapshotLocked(new TeamsMuteSyncSnapshot(
                            TeamsMuteSyncStatus.WaitingForPairingApproval,
                            null,
                            update.CanPair ? "Teams is waiting for pairing approval." : null,
                            false,
                            false,
                            false));
                    }
                    else if (update.State is { } state)
                    {
                        SetSnapshotLocked(snapshot with
                        {
                            LastMeetingState = state,
                            Status = state.IsInMeeting ? TeamsMuteSyncStatus.InMeeting : TeamsMuteSyncStatus.Ready,
                            Detail = null,
                            IsPairingAuthenticated = true,
                            IsMicrophoneRoutingEngaged = false,
                            IsPairingKnown = true,
                        });
                        PublishMeetingEvidenceLocked(revision => state.IsInMeeting
                            ? new TeamsMeetingEvidence.JoinedConfirmed(client.TransportSnapshot.Generation, revision)
                            : new TeamsMeetingEvidence.LeftConfirmed(client.TransportSnapshot.Generation, revision));
                        MeetingPresenceChanged?.Invoke(this, state.IsInMeeting);
                    }
                    else
                    {
                        // A permissions-only or otherwise partial update is diagnostic, not a
                        // meeting transition. Preserve the last complete trusted state until an
                        // explicit connection loss, API error, or complete state changes it.
                        // This is essential because Teams can send these updates independently
                        // of meetingUpdate pushes while a meeting remains active.
                    }
                    break;
                case TeamsThirdPartyApiEvent.Error(_, var message) when IsAlreadyPairedResponse(message):
                    // Only the user's own pair command can enter the actionable reset state.
                    if (pairingRequestPending)
                    {
                        pairingRequestPending = false;
                        FailClosedForLostTrustLocked();
                        SetSnapshotLocked(new TeamsMuteSyncSnapshot(
                            TeamsMuteSyncStatus.Failed,
                            null,
                            "Teams reports this recorder is already paired. In Teams, open Settings > Privacy > Manage API, forget Local Meeting Recorder, then request pairing again.",
                            false,
                            false));
                    }
                    break;
                case TeamsThirdPartyApiEvent.Error(_, var message):
                    pairingRequestPending = false;
                    FailClosedForLostTrustLocked();
                    SetSnapshotLocked(new TeamsMuteSyncSnapshot(TeamsMuteSyncStatus.Failed, null, message, false, false));
                    break;
            }
        }
    }

    private void OnConnectionChanged(object? sender, string? error)
    {
        lock (gate)
        {
            if (!enabled) return;
            pairingRequestPending = false;
            FailClosedForLostTrustLocked();
            SetSnapshotLocked(new TeamsMuteSyncSnapshot(TeamsMuteSyncStatus.WaitingForTeamsApi, null, error, false, false));
        }
    }

    private void FailClosedForLostTrustLocked()
    {
        var wasTrustedMeeting = snapshot.IsPairingAuthenticated && snapshot.LastMeetingState is { IsInMeeting: true };
        if (wasTrustedMeeting)
            PublishMeetingEvidenceLocked(revision => new TeamsMeetingEvidence.StateUnavailable(
                client.TransportSnapshot.Generation, revision));
    }

    private void PublishMeetingEvidenceLocked(Func<long, TeamsMeetingEvidence> create) =>
        MeetingEvidenceChanged?.Invoke(this, create(checked(++meetingEvidenceRevision)));

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
