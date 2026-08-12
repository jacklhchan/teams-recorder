using TeamsRecorder.Windows.Application.Control;

return await RecorderControlCli.RunAsync(args, Console.Out, Console.Error, CancellationToken.None);

internal static class RecorderControlCli
{
    private const string Usage = "Usage: recorderctl status [--json] | watch [--json] | start | stop | auto on|off | mic mute|unmute";

    public static async Task<int> RunAsync(
        string[] arguments,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken)
    {
        if (!TryParse(arguments, out var command, out var json))
        {
            await error.WriteLineAsync(Usage).ConfigureAwait(false);
            return 2;
        }

        var client = new RecorderControlPipeClient();
        if (command.Command == RecorderControlCommand.Status && arguments.Length > 0 && arguments[0] == "watch")
        {
            return await WatchAsync(client, json, output, error, cancellationToken).ConfigureAwait(false);
        }

        return await SendOnceAsync(client, command, json, output, error, cancellationToken).ConfigureAwait(false);
    }

    private static async Task<int> WatchAsync(
        RecorderControlPipeClient client,
        bool json,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken)
    {
        RecorderControlStatus? previous = null;
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var response = await client.SendAsync(
                        RecorderControlCommand.Status,
                        timeout: TimeSpan.FromSeconds(5),
                        cancellationToken: cancellationToken)
                    .ConfigureAwait(false);
                if (!response.Ok || response.Status is null)
                {
                    await error.WriteLineAsync($"error [{response.Error?.Code ?? "malformed_response"}]: {response.Error?.Message ?? "Recorder returned no status."}")
                        .ConfigureAwait(false);
                    return 4;
                }

                if (response.Status != previous)
                {
                    await RenderAsync(response.Status, json, output).ConfigureAwait(false);
                    previous = response.Status;
                }
                await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
            }
            return 0;
        }
        catch (OperationCanceledException)
        {
            return 0;
        }
        catch (RecorderControlProtocolException exception)
        {
            await error.WriteLineAsync($"error: {DescribeProtocolError(exception.Error)}").ConfigureAwait(false);
            return 3;
        }
        catch (IOException)
        {
            await error.WriteLineAsync("error: Recorder control service is unavailable.").ConfigureAwait(false);
            return 3;
        }
    }

    private static async Task<int> SendOnceAsync(
        RecorderControlPipeClient client,
        (RecorderControlCommand Command, string? Argument) command,
        bool json,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken)
    {
        try
        {
            var response = await client.SendAsync(command.Command, command.Argument, TimeSpan.FromSeconds(5), cancellationToken)
                .ConfigureAwait(false);
            if (!response.Ok || response.Status is null)
            {
                await error.WriteLineAsync($"error [{response.Error?.Code ?? "malformed_response"}]: {response.Error?.Message ?? "Recorder rejected the operation."}")
                    .ConfigureAwait(false);
                return 4;
            }

            await RenderAsync(response.Status, json, output).ConfigureAwait(false);
            return 0;
        }
        catch (OperationCanceledException)
        {
            return 0;
        }
        catch (RecorderControlProtocolException exception)
        {
            await error.WriteLineAsync($"error: {DescribeProtocolError(exception.Error)}").ConfigureAwait(false);
            return 3;
        }
        catch (IOException)
        {
            await error.WriteLineAsync("error: Recorder control service is unavailable.").ConfigureAwait(false);
            return 3;
        }
    }

    private static async Task RenderAsync(RecorderControlStatus status, bool json, TextWriter output)
    {
        if (json)
        {
            await output.WriteLineAsync(RecorderControlProtocol.SerializeStatusJson(status)).ConfigureAwait(false);
            return;
        }

        await output.WriteLineAsync($"App: {(status.AppRunning ? "running" : "not running")} ({status.AppVersion})").ConfigureAwait(false);
        await output.WriteLineAsync($"Recording: {status.RecordingState.ToString().ToLowerInvariant()}").ConfigureAwait(false);
        await output.WriteLineAsync($"Lifecycle operation: {status.LifecycleOperation.ToString().ToLowerInvariant()}").ConfigureAwait(false);
        await output.WriteLineAsync($"Elapsed seconds: {status.ElapsedSeconds?.ToString() ?? "-"}").ConfigureAwait(false);
        await output.WriteLineAsync($"Recorder mic muted: {(status.MicrophoneMuted ? "yes" : "no")}").ConfigureAwait(false);
        await output.WriteLineAsync($"Auto Mode enabled: {(status.AutoModeEnabled ? "yes" : "no")}").ConfigureAwait(false);
    }

    private static bool TryParse(
        string[] arguments,
        out (RecorderControlCommand Command, string? Argument) command,
        out bool json)
    {
        json = false;
        command = default;
        switch (arguments)
        {
            case ["status"]:
            case ["status", "--json"]:
                json = arguments.Length == 2;
                command = (RecorderControlCommand.Status, null);
                return true;
            case ["watch"]:
            case ["watch", "--json"]:
                json = arguments.Length == 2;
                command = (RecorderControlCommand.Status, null);
                return true;
            case ["start"]:
                command = (RecorderControlCommand.Start, null);
                return true;
            case ["stop"]:
                command = (RecorderControlCommand.Stop, null);
                return true;
            case ["auto", "on"]:
            case ["auto", "off"]:
                command = (RecorderControlCommand.SetAuto, arguments[1]);
                return true;
            case ["mic", "mute"]:
            case ["mic", "unmute"]:
                command = (RecorderControlCommand.SetMic, arguments[1]);
                return true;
            default:
                return false;
        }
    }

    private static string DescribeProtocolError(RecorderControlProtocolError error) => error switch
    {
        RecorderControlProtocolError.TimedOut => "Recorder control request timed out.",
        RecorderControlProtocolError.UnauthorizedPeer => "Recorder control peer identity was rejected.",
        RecorderControlProtocolError.ServiceStopped => "Recorder control service is stopped.",
        _ => "Recorder control service returned an invalid response.",
    };
}
