namespace TeamsRecorder.Windows.Application;

/// <summary>Health of the state channel, distinct from pairing credential presence.</summary>
public enum TeamsTransportHealth { Unknown, Healthy, Degraded, Unavailable, PairingRequired }

public sealed record TeamsTransportHealthAssessment(TeamsTransportHealth Status, string Detail)
{
    public bool IsTrustedForAutomaticRecording => Status == TeamsTransportHealth.Healthy;
}

/// <summary>
/// Keeps state-sync claims conservative. Teams has no separate "currently in a meeting"
/// transport signal, therefore a connected socket with acknowledgements but no complete
/// <c>meetingState</c> is deliberately reported as degraded after a bounded grace period.
/// </summary>
public static class TeamsTransportHealthAdvisor
{
    public static readonly TimeSpan InitialStateGrace = TimeSpan.FromSeconds(15);

    public static TeamsTransportHealthAssessment Assess(TeamsTransportDiagnosticSnapshot snapshot, DateTimeOffset nowUtc)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!snapshot.IsRunning || !snapshot.IsConnected)
            return new(TeamsTransportHealth.Unavailable, "Teams API 尚未連線，無法驗證會議狀態。");
        if (!snapshot.PairingCredentialPresent)
            return new(TeamsTransportHealth.PairingRequired, "Teams 尚未提供此裝置的配對憑證。");

        var connectedAt = snapshot.ConnectedAtUtc;
        if (connectedAt is null || nowUtc < connectedAt.Value + InitialStateGrace)
            return new(TeamsTransportHealth.Unknown, "已連線且有配對憑證；正在等待 Teams 提供完整會議狀態。");

        // This API is push-only: it has no heartbeat contract. A quiet socket after a
        // complete state is not evidence that the state channel failed. Connection
        // generations are reset by the client on reconnect, so this evidence cannot leak
        // from an older socket.
        if (snapshot.LastAuthoritativeMeetingStateUtc is not null)
            return new(TeamsTransportHealth.Healthy, "本連線世代已收到完整 Teams 會議狀態。");

        var queryDetail = snapshot.LastQueryOutcome switch
        {
            "acknowledged" => "查詢已確認，但 Teams 沒有提供 meetingState/isInMeeting。",
            "rejected" => "Teams 拒絕狀態查詢，且尚未收到完整 meetingState。",
            "timed-out" => "Teams 狀態查詢已逾時，且尚未收到完整 meetingState。",
            _ => "尚未收到完整 meetingState/isInMeeting。",
        };
        return new(TeamsTransportHealth.Degraded,
            $"{queryDetail} 已收到 {snapshot.StateLessMeetingUpdateCount} 個不含完整狀態的更新；API 並未證實可供自動錄音使用。");
    }
}
