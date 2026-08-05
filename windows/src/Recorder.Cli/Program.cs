using System.IO.Pipes;
using System.Text.Json;
using TeamsRecorder.Windows.Application.Control;

return await RecorderCli.RunAsync(args);

internal static class RecorderCli
{
    private static readonly JsonSerializerOptions WireOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
    };

    private static readonly JsonSerializerOptions DisplayOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = false,
    };

    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length == 0 || args[0] is "help" or "--help" or "-h")
        {
            PrintUsage();
            return args.Length == 0 ? 2 : 0;
        }

        try
        {
            if (args[0].Equals("watch", StringComparison.OrdinalIgnoreCase))
            {
                return await WatchAsync();
            }

            var (command, muted) = ParseCommand(args);
            long? generation = null;
            if (command != RecorderControlProtocol.Status)
            {
                var status = await SendAsync(new(
                    RecorderControlProtocol.SchemaVersion,
                    Guid.NewGuid().ToString("N"),
                    RecorderControlProtocol.Status));
                if (!status.Ok)
                {
                    PrintResponse(status);
                    return 4;
                }
                generation = ((JsonElement)status.Result!).GetProperty("generation").GetInt64();
            }

            var response = await SendAsync(new(
                RecorderControlProtocol.SchemaVersion,
                Guid.NewGuid().ToString("N"),
                command,
                generation,
                muted));
            PrintResponse(response);
            return response.Ok ? 0 : 4;
        }
        catch (ArgumentException exception)
        {
            Console.Error.WriteLine(exception.Message);
            PrintUsage();
            return 2;
        }
        catch (TimeoutException)
        {
            Console.Error.WriteLine("Recorder control pipe is unavailable. Start Teams Recorder first.");
            return 3;
        }
        catch (IOException exception)
        {
            Console.Error.WriteLine($"Recorder control pipe failed: {exception.Message}");
            return 3;
        }
    }

    private static (string Command, bool? Muted) ParseCommand(string[] args) => args[0].ToLowerInvariant() switch
    {
        "status" when args.Length == 1 => (RecorderControlProtocol.Status, null),
        "devices" when args.Length == 1 => (RecorderControlProtocol.RefreshDevices, null),
        "teams" when args.Length == 1 => (RecorderControlProtocol.RefreshTeams, null),
        "pair" when args.Length == 1 => (RecorderControlProtocol.PairTeams, null),
        "reset-pairing" when args.Length == 1 => (RecorderControlProtocol.ResetTeamsPairing, null),
        "start" when args.Length == 1 => (RecorderControlProtocol.Start, null),
        "test" when args.Length == 1 => (RecorderControlProtocol.Test, null),
        "stop" when args.Length == 1 => (RecorderControlProtocol.Stop, null),
        "diagnostics" when args.Length == 1 => (RecorderControlProtocol.Diagnostics, null),
        "mute" when args.Length == 2 && args[1].Equals("on", StringComparison.OrdinalIgnoreCase) =>
            (RecorderControlProtocol.SetMicrophoneMute, true),
        "mute" when args.Length == 2 && args[1].Equals("off", StringComparison.OrdinalIgnoreCase) =>
            (RecorderControlProtocol.SetMicrophoneMute, false),
        _ => throw new ArgumentException("Unknown command or arguments."),
    };

    private static async Task<int> WatchAsync()
    {
        using var cancellation = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellation.Cancel();
        };
        try
        {
            while (!cancellation.IsCancellationRequested)
            {
                Console.Clear();
                PrintResponse(await SendAsync(new(
                    RecorderControlProtocol.SchemaVersion,
                    Guid.NewGuid().ToString("N"),
                    RecorderControlProtocol.Status), cancellation.Token));
                await Task.Delay(TimeSpan.FromSeconds(1), cancellation.Token);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        return 0;
    }

    private static async Task<RecorderControlResponse> SendAsync(
        RecorderControlRequest request,
        CancellationToken cancellationToken = default)
    {
        await using var pipe = new NamedPipeClientStream(
            ".",
            RecorderControlProtocol.PipeName(),
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        await pipe.ConnectAsync(2000, cancellationToken);
        // The pipe is newline-delimited. Wire JSON must stay on exactly one line;
        // indentation is only for terminal output.
        var bytes = RecorderControlProtocol.SerializeRequest(request);
        await pipe.WriteAsync(bytes, cancellationToken);
        await pipe.WriteAsync("\n"u8.ToArray(), cancellationToken);
        await pipe.FlushAsync(cancellationToken);

        using var response = new MemoryStream();
        var one = new byte[1];
        while (response.Length <= RecorderControlProtocol.MaxResponseBytes)
        {
            var read = await pipe.ReadAsync(one, cancellationToken);
            if (read == 0) throw new IOException("Recorder closed the control response early.");
            if (one[0] == (byte)'\n')
            {
                return JsonSerializer.Deserialize<RecorderControlResponse>(response.ToArray(), WireOptions)
                    ?? throw new IOException("Recorder returned an empty response.");
            }
            response.WriteByte(one[0]);
        }
        throw new IOException("Recorder response exceeded the 64 KiB protocol limit.");
    }

    private static void PrintResponse(RecorderControlResponse response)
    {
        Console.WriteLine(JsonSerializer.Serialize(response, DisplayOptions));
    }

    private static void PrintUsage()
    {
        Console.WriteLine("Teams Recorder control CLI");
        Console.WriteLine("  teams-recorder status | watch | devices | teams | pair | reset-pairing");
        Console.WriteLine("  teams-recorder start | test | stop | mute on|off | diagnostics");
        Console.WriteLine("The WinUI recorder must be running under the same Windows user.");
    }
}
