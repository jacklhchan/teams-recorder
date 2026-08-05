namespace TeamsRecorder.Windows.Application;

/// <summary>
/// The bounded evidence Windows can observe without the retired Teams device API.
/// An active render session is produced by the native WASAPI probe, which verifies
/// that the owning image is Teams.exe or ms-teams.exe. It is still a heuristic:
/// notification sounds can briefly activate it and a silent meeting can hide it.
/// </summary>
public sealed record TeamsLocalMeetingObservation(
    DateTimeOffset ObservedAtUtc,
    bool ProbeAvailable,
    bool TeamsProcessPresent,
    IReadOnlyList<string> ActiveRenderEndpointIds)
{
    public bool HasActiveTeamsRenderSession => ProbeAvailable && ActiveRenderEndpointIds.Count > 0;

    public static TeamsLocalMeetingObservation ProbeFailure(DateTimeOffset observedAtUtc, bool teamsProcessPresent) =>
        new(observedAtUtc, false, teamsProcessPresent, Array.Empty<string>());
}

public enum TeamsLocalMeetingHealth
{
    Unavailable,
    WaitingForTeams,
    WaitingForAudio,
    Candidate,
    MeetingLikely,
    EvidenceLost,
}

/// <summary>
/// Explicit capability boundary for the local workaround. Windows can mute the
/// microphone contribution in this recorder, but it cannot read or change the
/// mute button inside Teams without an authoritative Teams API.
/// </summary>
public sealed record TeamsLocalMuteCapability(
    bool CanReadTeamsMute,
    bool CanWriteTeamsMute,
    bool CanMuteRecorderMicrophone)
{
    public static TeamsLocalMuteCapability RecorderOnly { get; } = new(false, false, true);
}

/// <summary>
/// Explicit user-consent seam for the heuristic. The safe default only reports
/// local evidence; it cannot forward a start request to the automatic recorder.
/// </summary>
public sealed record TeamsLocalHeuristicPolicy(bool EnableLocalHeuristicAutoStart = false)
{
    public static TeamsLocalHeuristicPolicy Disabled { get; } = new();
}

public sealed record TeamsLocalMeetingSnapshot(
    TeamsLocalMeetingHealth Health,
    int ConsecutiveActiveObservations,
    bool StartSignalLatched,
    bool ShouldTriggerAutomaticStart,
    DateTimeOffset? FirstActiveObservationUtc,
    DateTimeOffset? LastActiveObservationUtc,
    string Detail,
    TeamsLocalMuteCapability MuteCapability);

/// <summary>
/// Fail-closed local meeting-start detector. A start is emitted once after a
/// bounded run of active Teams render-session observations. Negative evidence
/// never means "meeting ended": the signal latches until the host explicitly
/// resets it after the user stops or cancels the recording.
/// </summary>
public sealed class TeamsLocalMeetingDetector
{
    public const int DefaultRequiredActiveObservations = 3;

    private readonly int requiredActiveObservations;
    private int consecutiveActiveObservations;
    private bool startSignalLatched;
    private bool automaticStartForwarded;
    private DateTimeOffset? firstActiveObservationUtc;
    private DateTimeOffset? lastActiveObservationUtc;

    public TeamsLocalMeetingDetector(int requiredActiveObservations = DefaultRequiredActiveObservations)
    {
        if (requiredActiveObservations < 2)
            throw new ArgumentOutOfRangeException(nameof(requiredActiveObservations), "At least two observations are required to reject transient notification audio.");
        this.requiredActiveObservations = requiredActiveObservations;
    }

    public TeamsLocalMeetingSnapshot Observe(
        TeamsLocalMeetingObservation observation,
        TeamsLocalHeuristicPolicy? policy = null)
    {
        ArgumentNullException.ThrowIfNull(observation);
        policy ??= TeamsLocalHeuristicPolicy.Disabled;

        if (!observation.ProbeAvailable)
        {
            consecutiveActiveObservations = 0;
            firstActiveObservationUtc = null;
            return Snapshot(
                startSignalLatched ? TeamsLocalMeetingHealth.EvidenceLost : TeamsLocalMeetingHealth.Unavailable,
                false,
                "Windows 無法讀取 Teams 的 WASAPI 播放工作階段；本機自動開始已停用。");
        }

        if (!observation.HasActiveTeamsRenderSession)
        {
            consecutiveActiveObservations = 0;
            firstActiveObservationUtc = null;
            var health = startSignalLatched
                ? TeamsLocalMeetingHealth.EvidenceLost
                : observation.TeamsProcessPresent
                    ? TeamsLocalMeetingHealth.WaitingForAudio
                    : TeamsLocalMeetingHealth.WaitingForTeams;
            var detail = startSignalLatched
                ? "先前的 Teams 播放訊號已消失；這不代表會議已結束，錄音不會被自動停止。"
                : observation.TeamsProcessPresent
                    ? "Teams 正在執行，但尚未持續觀察到 Teams 播放音訊工作階段。"
                    : "尚未觀察到 Teams 程序或 Teams 播放音訊工作階段。";
            return Snapshot(health, false, detail);
        }

        lastActiveObservationUtc = observation.ObservedAtUtc;
        if (startSignalLatched)
        {
            var forwardNow = policy.EnableLocalHeuristicAutoStart && !automaticStartForwarded;
            automaticStartForwarded |= forwardNow;
            return Snapshot(TeamsLocalMeetingHealth.MeetingLikely, forwardNow,
                forwardNow
                    ? "使用者已啟用本機推測自動開始；可將一次倒數開始訊號交給錄音控制器。"
                    : automaticStartForwarded
                        ? "已送出一次本機 Teams 推測開始訊號；不會重複觸發。"
                        : "已偵測到可能的 Teams 會議；本機推測自動開始尚未啟用，僅顯示提示。" );
        }

        firstActiveObservationUtc ??= observation.ObservedAtUtc;
        consecutiveActiveObservations = checked(consecutiveActiveObservations + 1);
        if (consecutiveActiveObservations < requiredActiveObservations)
            return Snapshot(TeamsLocalMeetingHealth.Candidate, false,
                $"已連續觀察到 {consecutiveActiveObservations}/{requiredActiveObservations} 次 Teams 播放訊號；正在排除通知音效。" );

        startSignalLatched = true;
        automaticStartForwarded = policy.EnableLocalHeuristicAutoStart;
        return Snapshot(
            TeamsLocalMeetingHealth.MeetingLikely,
            automaticStartForwarded,
            automaticStartForwarded
                ? "使用者已啟用本機推測自動開始；可將一次倒數開始訊號交給錄音控制器。"
                : "已偵測到可能的 Teams 會議；本機推測自動開始尚未啟用，僅顯示提示。" );
    }

    /// <summary>Called only after the host has explicitly ended/cancelled the locally detected session.</summary>
    public void Reset()
    {
        consecutiveActiveObservations = 0;
        startSignalLatched = false;
        automaticStartForwarded = false;
        firstActiveObservationUtc = null;
        lastActiveObservationUtc = null;
    }

    private TeamsLocalMeetingSnapshot Snapshot(TeamsLocalMeetingHealth health, bool trigger, string detail) =>
        new(health, consecutiveActiveObservations, startSignalLatched, trigger,
            firstActiveObservationUtc, lastActiveObservationUtc, detail,
            TeamsLocalMuteCapability.RecorderOnly);
}

/// <summary>Samples existing process-catalog and native WASAPI capabilities without capture side effects.</summary>
public interface ITeamsLocalMeetingSignalSampler
{
    TeamsLocalMeetingObservation Sample(DateTimeOffset observedAtUtc);
}

public sealed class TeamsLocalMeetingSignalSampler(
    IProcessCatalog processCatalog,
    INativeTeamsRenderEndpointProbe renderEndpointProbe) : ITeamsLocalMeetingSignalSampler
{
    public TeamsLocalMeetingObservation Sample(DateTimeOffset observedAtUtc)
    {
        var teamsPresent = TeamsProcessCatalogPolicy.FilterForTeams(processCatalog.GetProcesses()).Count > 0;
        try
        {
            var result = renderEndpointProbe.ProbeTeamsRenderEndpoints();
            return result.IsSuccess
                ? new TeamsLocalMeetingObservation(
                    observedAtUtc,
                    true,
                    teamsPresent,
                    result.ActiveEndpoints.Select(endpoint => endpoint.EndpointId).ToArray())
                : TeamsLocalMeetingObservation.ProbeFailure(observedAtUtc, teamsPresent);
        }
        catch
        {
            return TeamsLocalMeetingObservation.ProbeFailure(observedAtUtc, teamsPresent);
        }
    }
}

/// <summary>
/// Owns cancellable, non-reentrant polling and the explicit hand-off to the
/// automatic-recording controller. It never emits meeting-left or mute state.
/// </summary>
public sealed class TeamsLocalHeuristicAutoStartHost : IAsyncDisposable
{
    private readonly ITeamsLocalMeetingSignalSampler sampler;
    private readonly TeamsLocalMeetingDetector detector;
    private readonly Func<CancellationToken, Task> forwardLocalMeetingCandidate;
    private readonly Func<DateTimeOffset> utcNow;
    private readonly SemaphoreSlim pollGate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly object snapshotGate = new();
    private TeamsLocalMeetingSnapshot? snapshot;
    private bool disposed;

    public TeamsLocalHeuristicAutoStartHost(
        ITeamsLocalMeetingSignalSampler sampler,
        Func<CancellationToken, Task> forwardLocalMeetingCandidate,
        TeamsLocalMeetingDetector? detector = null,
        Func<DateTimeOffset>? utcNow = null)
    {
        this.sampler = sampler ?? throw new ArgumentNullException(nameof(sampler));
        this.forwardLocalMeetingCandidate = forwardLocalMeetingCandidate ?? throw new ArgumentNullException(nameof(forwardLocalMeetingCandidate));
        this.detector = detector ?? new TeamsLocalMeetingDetector();
        this.utcNow = utcNow ?? (() => DateTimeOffset.UtcNow);
    }

    public TeamsLocalMeetingSnapshot? Snapshot
    {
        get { lock (snapshotGate) return snapshot; }
    }

    public async Task<TeamsLocalMeetingSnapshot?> PollAsync(
        TeamsLocalHeuristicPolicy policy,
        TeamsTransportHealth transportHealth,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(policy);
        ThrowIfDisposed();
        if (!policy.EnableLocalHeuristicAutoStart ||
            transportHealth is not (TeamsTransportHealth.Degraded or TeamsTransportHealth.Unavailable))
        {
            return Snapshot;
        }

        if (!await pollGate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
            return Snapshot;

        try
        {
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lifetime.Token);
            var observation = await Task.Run(() => sampler.Sample(utcNow()), linked.Token).ConfigureAwait(false);
            linked.Token.ThrowIfCancellationRequested();
            var changed = detector.Observe(observation, policy);
            lock (snapshotGate) snapshot = changed;
            if (changed.ShouldTriggerAutomaticStart)
                await forwardLocalMeetingCandidate(linked.Token).ConfigureAwait(false);
            return changed;
        }
        finally
        {
            pollGate.Release();
        }
    }

    public void Reset()
    {
        ThrowIfDisposed();
        detector.Reset();
        lock (snapshotGate) snapshot = null;
    }

    public ValueTask DisposeAsync()
    {
        if (disposed) return ValueTask.CompletedTask;
        disposed = true;
        lifetime.Cancel();
        lifetime.Dispose();
        return ValueTask.CompletedTask;
    }

    private void ThrowIfDisposed()
    {
        if (disposed) throw new ObjectDisposedException(nameof(TeamsLocalHeuristicAutoStartHost));
    }
}
