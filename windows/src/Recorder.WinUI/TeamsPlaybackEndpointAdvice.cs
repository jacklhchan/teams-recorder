using Recorder.Core;
using TeamsRecorder.Windows.Application;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Presents an intentionally conservative endpoint check.  The public Teams
/// integration used by this app does not disclose Teams' speaker endpoint.
/// Windows may, however, expose a transient active audio-session hint. The
/// advice falls back to a manual check when that hint is unavailable and never
/// changes the Teams client setting.
/// </summary>
internal static class TeamsPlaybackEndpointAdvice
{
    public static string? GetWarning(
        CaptureSourceKind? sourceKind,
        EndpointChoice? renderEndpoint,
        string? windowsConsoleDefaultRenderEndpointId,
        TeamsPlaybackEndpointObservation teamsPlayback)
    {
        if (sourceKind == CaptureSourceKind.SelectedApplication || renderEndpoint is null)
        {
            return null;
        }

        if (!renderEndpoint.IsAvailable)
        {
            return "已選的輸出裝置目前不可用。請重新整理裝置，並在 Teams 的「設定 > 裝置 > 喇叭」選擇同一個可用的播放端點。";
        }

        var request = new RecordingStartRequest(
            RecordingSessionKind.Manual,
            RecordingAudioSource.SystemLoopback,
            RenderEndpointId: renderEndpoint.EndpointId);
        var observed = TeamsPlaybackEndpointMismatchPolicy.Evaluate(
            request,
            windowsConsoleDefaultRenderEndpointId,
            teamsPlayback);
        if (observed.HasWarning)
        {
            return observed.Message;
        }

        // A currently active Teams session was found and it maps to this
        // recorder endpoint. There is no mismatch to warn about.
        if (teamsPlayback.IsKnown)
        {
            return null;
        }

        return renderEndpoint.EndpointId is null
            ? "目前使用 Windows 預設輸出裝置。Teams 可能播放到另一個耳機或喇叭；開始錄音前，請重新整理裝置，並明確選擇與 Teams「設定 > 裝置 > 喇叭」相同的播放端點。"
            : $"Recorder 會錄製「{renderEndpoint.DisplayName}」。請確認 Teams「設定 > 裝置 > 喇叭」也使用此端點；Teams API 不會提供或自動變更該設定。";
    }
}
