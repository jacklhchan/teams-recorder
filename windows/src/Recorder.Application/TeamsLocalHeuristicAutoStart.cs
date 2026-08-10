namespace TeamsRecorder.Windows.Application;

/// <summary>
/// The bounded evidence Windows can observe without the retired Teams device API.
/// Render-session activity is a heuristic, not an authoritative meeting state.
/// </summary>
public sealed record TeamsLocalHeuristicObservation(
    DateTimeOffset ObservedAtUtc,
    bool ProbeAvailable,
    bool TeamsProcessPresent,
    IReadOnlyList<string> ActiveRenderEndpointIds)
{
    public bool HasActiveTeamsRenderSession => ProbeAvailable && ActiveRenderEndpointIds.Count > 0;

    public static TeamsLocalHeuristicObservation ProbeFailure(DateTimeOffset observedAtUtc, bool teamsProcessPresent) =>
        new(observedAtUtc, false, teamsProcessPresent, Array.Empty<string>());
}

public enum TeamsLocalMeetingHealth { Unavailable, WaitingForTeams, WaitingForAudio, Candidate, MeetingLikely, EvidenceLost, MeetingEndedLikely }

/// <summary>Recorder microphone controls are local only; Teams mute is never read or written.</summary>
public sealed record TeamsLocalMuteCapability(bool CanReadTeamsMute, bool CanWriteTeamsMute, bool CanMuteRecorderMicrophone)
{
    public static TeamsLocalMuteCapability RecorderOnly { get; } = new(false, false, true);
}

public sealed record TeamsLocalHeuristicPolicy(bool EnableLocalHeuristicAutoStart = false)
{
    public static TeamsLocalHeuristicPolicy Disabled { get; } = new();
}

public sealed record TeamsLocalMeetingSnapshot(
    TeamsLocalMeetingHealth Health,
    int ConsecutiveActiveObservations,
    int ConsecutiveMissingObservations,
    bool StartSignalLatched,
    bool ShouldTriggerAutomaticStart,
    bool ShouldTriggerAutomaticStop,
    string Detail,
    TeamsLocalMuteCapability MuteCapability);

/// <summary>
/// Emits one start after three active Teams render-session samples. Silence and
/// probe failure never stop capture; only three healthy samples with no Teams
/// process can emit one stop request.
/// </summary>
public sealed class TeamsLocalMeetingHeuristic
{
    public const int RequiredActiveObservations = 3;
    public const int RequiredMissingProcessObservations = 3;
    private int active;
    private int missing;
    private bool latched;
    private bool startForwarded;
    private bool stopForwarded;

    public TeamsLocalMeetingSnapshot Observe(TeamsLocalHeuristicObservation observation, TeamsLocalHeuristicPolicy? policy = null)
    {
        ArgumentNullException.ThrowIfNull(observation);
        policy ??= TeamsLocalHeuristicPolicy.Disabled;
        if (!observation.ProbeAvailable)
        {
            active = 0;
            missing = 0;
            return Snapshot(latched ? TeamsLocalMeetingHealth.EvidenceLost : TeamsLocalMeetingHealth.Unavailable, false, false,
                "Windows 無法讀取 Teams 的 WASAPI 播放工作階段；探針失敗不會觸發自動開始或停止。");
        }

        if (!observation.HasActiveTeamsRenderSession)
        {
            active = 0;
            missing = latched && !observation.TeamsProcessPresent ? checked(missing + 1) : 0;
            var stop = latched && !stopForwarded && !observation.TeamsProcessPresent &&
                missing >= RequiredMissingProcessObservations && policy.EnableLocalHeuristicAutoStart;
            stopForwarded |= stop;
            return Snapshot(
                stopForwarded ? TeamsLocalMeetingHealth.MeetingEndedLikely : latched ? TeamsLocalMeetingHealth.EvidenceLost : observation.TeamsProcessPresent ? TeamsLocalMeetingHealth.WaitingForAudio : TeamsLocalMeetingHealth.WaitingForTeams,
                false, stop,
                stopForwarded ? "Teams 程序已連續 3 次不存在；已提出一次本機推測停止。" :
                latched && observation.TeamsProcessPresent ? "Teams 播放工作階段沒有活動；這可能只是會議沉默，因此不會自動停止。" :
                latched ? $"Teams 程序目前不存在（{missing}/3）；尚未提出停止。" :
                observation.TeamsProcessPresent ? "Teams 正在執行，但尚未持續觀察到 Teams 播放音訊工作階段。" : "尚未觀察到 Teams 程序或 Teams 播放音訊工作階段。");
        }

        missing = 0;
        if (!latched)
        {
            active = checked(active + 1);
            if (active < RequiredActiveObservations)
                return Snapshot(TeamsLocalMeetingHealth.Candidate, false, false, $"已連續觀察到 {active}/3 次 Teams 播放訊號；正在排除通知音效。");
            latched = true;
        }

        var restarted = stopForwarded;
        stopForwarded = false;
        var start = policy.EnableLocalHeuristicAutoStart && (!startForwarded || restarted);
        startForwarded |= start;
        return Snapshot(TeamsLocalMeetingHealth.MeetingLikely, start, false,
            start ? restarted ? "Teams 播放訊號已恢復；已送出一次本機推測開始訊號。" : "已送出一次本機 Teams 推測開始訊號。" : "已偵測到可能的 Teams 會議；本機自動開始尚未啟用。");
    }

    public void Reset() { active = 0; missing = 0; latched = false; startForwarded = false; stopForwarded = false; }

    private TeamsLocalMeetingSnapshot Snapshot(TeamsLocalMeetingHealth health, bool start, bool stop, string detail) =>
        new(health, active, missing, latched, start, stop, detail, TeamsLocalMuteCapability.RecorderOnly);
}

public interface ITeamsLocalMeetingSignalSampler { TeamsLocalHeuristicObservation Sample(DateTimeOffset observedAtUtc); }

public sealed class TeamsLocalMeetingSignalSampler(IProcessCatalog processCatalog, INativeTeamsRenderEndpointProbe renderEndpointProbe) : ITeamsLocalMeetingSignalSampler
{
    public TeamsLocalHeuristicObservation Sample(DateTimeOffset observedAtUtc)
    {
        var teamsPresent = TeamsProcessCatalogPolicy.FilterForTeams(processCatalog.GetProcesses()).Count > 0;
        try
        {
            var result = renderEndpointProbe.ProbeTeamsRenderEndpoints();
            return result.IsSuccess
                ? new TeamsLocalHeuristicObservation(observedAtUtc, true, teamsPresent, result.ActiveEndpoints.Select(endpoint => endpoint.EndpointId).ToArray())
                : TeamsLocalHeuristicObservation.ProbeFailure(observedAtUtc, teamsPresent);
        }
        catch { return TeamsLocalHeuristicObservation.ProbeFailure(observedAtUtc, teamsPresent); }
    }
}

/// <summary>Owns non-reentrant polling and has no Teams API, token, or mute dependency.</summary>
public sealed class TeamsLocalHeuristicAutoStartHost : IAsyncDisposable
{
    private readonly ITeamsLocalMeetingSignalSampler sampler;
    private readonly TeamsLocalMeetingHeuristic heuristic;
    private readonly Func<CancellationToken, Task> onStart;
    private readonly Func<CancellationToken, Task> onStop;
    private readonly SemaphoreSlim pollGate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private TeamsLocalMeetingSnapshot? snapshot;
    private bool disposed;

    public TeamsLocalHeuristicAutoStartHost(ITeamsLocalMeetingSignalSampler sampler, Func<CancellationToken, Task> onStart, Func<CancellationToken, Task> onStop, TeamsLocalMeetingHeuristic? heuristic = null)
    { this.sampler = sampler ?? throw new ArgumentNullException(nameof(sampler)); this.onStart = onStart ?? throw new ArgumentNullException(nameof(onStart)); this.onStop = onStop ?? throw new ArgumentNullException(nameof(onStop)); this.heuristic = heuristic ?? new(); }

    public TeamsLocalMeetingSnapshot? Snapshot => snapshot;

    public async Task<TeamsLocalMeetingSnapshot?> PollAsync(TeamsLocalHeuristicPolicy policy, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(policy);
        if (disposed || !policy.EnableLocalHeuristicAutoStart || !await pollGate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return snapshot;
        try
        {
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lifetime.Token);
            var observed = await Task.Run(() => sampler.Sample(DateTimeOffset.UtcNow), linked.Token).ConfigureAwait(false);
            var changed = heuristic.Observe(observed, policy);
            snapshot = changed;
            if (changed.ShouldTriggerAutomaticStart) await onStart(linked.Token).ConfigureAwait(false);
            if (changed.ShouldTriggerAutomaticStop) await onStop(linked.Token).ConfigureAwait(false);
            return changed;
        }
        finally { pollGate.Release(); }
    }

    public async Task ResetAsync(CancellationToken cancellationToken = default)
    {
        if (disposed) return;
        await pollGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!disposed)
            {
                heuristic.Reset();
                snapshot = null;
            }
        }
        finally { pollGate.Release(); }
    }
    public ValueTask DisposeAsync() { if (!disposed) { disposed = true; lifetime.Cancel(); lifetime.Dispose(); } return ValueTask.CompletedTask; }
}
