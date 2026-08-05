using System.Text.Json;
using TeamsRecorder.Windows.Application.Control;

internal static class ControlProtocolTests
{
    public static void PipeNameIsPerUserAndNonSensitive()
    {
        var first = RecorderControlProtocol.PipeName();
        var second = RecorderControlProtocol.PipeName();
        if (!string.Equals(first, second, StringComparison.Ordinal))
            throw new InvalidOperationException("The current user's control pipe name must be stable.");
        if (!first.StartsWith("TeamsRecorder.Control.v1.", StringComparison.Ordinal) || first.Length > 64)
            throw new InvalidOperationException("The control pipe name is malformed.");
        if (first.Contains(Environment.UserName, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The pipe name must not disclose the Windows user name.");
    }

    public static void CommandAllowListIsClosed()
    {
        var expected = new[]
        {
            RecorderControlProtocol.Status,
            RecorderControlProtocol.RefreshDevices,
            RecorderControlProtocol.Start,
            RecorderControlProtocol.Test,
            RecorderControlProtocol.Stop,
            RecorderControlProtocol.SetMicrophoneMute,
            RecorderControlProtocol.Diagnostics,
        };
        if (expected.Any(command => !RecorderControlProtocol.IsSupportedCommand(command)))
            throw new InvalidOperationException("A documented local control command is missing.");
        if (RecorderControlProtocol.IsSupportedCommand(RecorderControlProtocol.Watch) ||
            RecorderControlProtocol.IsSupportedCommand("shell") ||
            RecorderControlProtocol.IsSupportedCommand("recording.delete"))
            throw new InvalidOperationException("The control protocol accepted a client-only or unsafe command.");
    }

    public static void RequestContractContainsNoPathsOrCredentials()
    {
        var request = new RecorderControlRequest(
            RecorderControlProtocol.SchemaVersion,
            "test-request",
            RecorderControlProtocol.Start,
            12);
        var json = JsonSerializer.Serialize(request, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        foreach (var forbidden in new[] { "token", "password", "path", "commandLine", "executable" })
        {
            if (json.Contains(forbidden, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException($"Control request leaked forbidden field: {forbidden}");
        }
        if (json.Length > RecorderControlProtocol.MaxRequestBytes)
            throw new InvalidOperationException("A minimal control request exceeded the protocol bound.");
    }

    public static void WireRequestIsOneJsonLine()
    {
        var request = new RecorderControlRequest(
            RecorderControlProtocol.SchemaVersion,
            "wire-test",
            RecorderControlProtocol.Status);
        var payload = RecorderControlProtocol.SerializeRequest(request);
        if (payload.Contains((byte)'\n') || payload.Contains((byte)'\r'))
            throw new InvalidOperationException("A wire request must not contain embedded newlines.");
        if (RecorderControlProtocol.DeserializeRequest(payload) != request)
            throw new InvalidOperationException("The control request did not round-trip.");
    }
}
