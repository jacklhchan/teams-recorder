using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

public static class RecordingStartMetadataPolicy
{
    public static WindowsCaptureMetadata CreateWindowsCaptureMetadata(RecordingStartRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();
        return request.AudioSource switch
        {
            RecordingAudioSource.SystemLoopback => WindowsCaptureMetadata.ForSystemLoopback(request.RenderEndpointId),
            RecordingAudioSource.SelectedProcessLoopback => WindowsCaptureMetadata.ForSelectedProcessLoopback(
                ToExecutableBasename(request.ProcessTarget!.ProcessName)),
            _ => throw new ArgumentOutOfRangeException(nameof(request)),
        };
    }

    private static string ToExecutableBasename(string processName) =>
        processName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
            ? processName
            : processName + ".exe";
}
