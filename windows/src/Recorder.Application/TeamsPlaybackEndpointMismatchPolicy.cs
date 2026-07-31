namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Produces a non-blocking warning when an independently observed Teams render
/// endpoint is not the endpoint the recorder will use for system loopback.
/// The Teams Third-party App API currently does not expose this information;
/// callers must pass <see cref="TeamsPlaybackEndpointObservation.Unknown"/>
/// until a platform-specific observer has obtained it.  This policy never
/// changes the user's device selection or captures an endpoint ID for logging.
/// </summary>
public static class TeamsPlaybackEndpointMismatchPolicy
{
    public static TeamsPlaybackEndpointWarning Evaluate(
        RecordingStartRequest request,
        string? windowsConsoleDefaultRenderEndpointId,
        TeamsPlaybackEndpointObservation teamsPlayback)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(teamsPlayback);
        request.Validate();

        if (request.AudioSource != RecordingAudioSource.SystemLoopback ||
            !teamsPlayback.IsKnown ||
            teamsPlayback.RenderEndpointIds.Count == 0)
        {
            return TeamsPlaybackEndpointWarning.None;
        }

        var recorderEndpointId = request.RenderEndpointId ?? windowsConsoleDefaultRenderEndpointId;
        if (string.IsNullOrWhiteSpace(recorderEndpointId) ||
            teamsPlayback.RenderEndpointIds.Contains(recorderEndpointId, StringComparer.Ordinal))
        {
            return TeamsPlaybackEndpointWarning.None;
        }

        return request.RenderEndpointId is null
            ? new TeamsPlaybackEndpointWarning(
                TeamsPlaybackEndpointWarningKind.DefaultRenderEndpointMismatch,
                "Teams 的播放裝置與 Windows 預設輸出裝置不同；系統音訊錄製可能收不到參與者聲音。請重新整理裝置，並選擇 Teams 正在使用的耳機／喇叭。")
            : new TeamsPlaybackEndpointWarning(
                TeamsPlaybackEndpointWarningKind.SelectedRenderEndpointMismatch,
                "Teams 的播放裝置與已選取的錄製輸出裝置不同；系統音訊錄製可能收不到參與者聲音。請選擇 Teams 正在使用的耳機／喇叭。");
    }
}

/// <summary>
/// An optional, transient result from a platform-specific Teams playback
/// observer.  Endpoint IDs remain in memory only and must not be written to
/// diagnostic reports.
/// </summary>
public sealed record TeamsPlaybackEndpointObservation(
    bool IsKnown,
    IReadOnlySet<string> RenderEndpointIds)
{
    public static TeamsPlaybackEndpointObservation Unknown { get; } = new(
        false,
        new HashSet<string>(StringComparer.Ordinal));

    public static TeamsPlaybackEndpointObservation Known(IEnumerable<string> renderEndpointIds)
    {
        ArgumentNullException.ThrowIfNull(renderEndpointIds);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var renderEndpointId in renderEndpointIds)
        {
            if (string.IsNullOrWhiteSpace(renderEndpointId) || renderEndpointId.IndexOf('\0') >= 0)
            {
                throw new ArgumentException("A valid render endpoint ID is required.", nameof(renderEndpointIds));
            }

            ids.Add(renderEndpointId);
        }

        return ids.Count == 0 ? Unknown : new(true, ids);
    }

    public static TeamsPlaybackEndpointObservation Known(string renderEndpointId) => Known([renderEndpointId]);
}

public enum TeamsPlaybackEndpointWarningKind
{
    None = 0,
    DefaultRenderEndpointMismatch = 1,
    SelectedRenderEndpointMismatch = 2,
}

public sealed record TeamsPlaybackEndpointWarning(TeamsPlaybackEndpointWarningKind Kind, string? Message)
{
    public static TeamsPlaybackEndpointWarning None { get; } = new(TeamsPlaybackEndpointWarningKind.None, null);
    public bool HasWarning => Kind != TeamsPlaybackEndpointWarningKind.None;
}
