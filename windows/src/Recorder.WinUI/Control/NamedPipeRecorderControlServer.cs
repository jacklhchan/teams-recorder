using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using TeamsRecorder.Windows.Application.Control;

namespace TeamsRecorder.Windows.WinUI.Control;

internal sealed class NamedPipeRecorderControlServer : IAsyncDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
    };

    private readonly RecordingViewModel viewModel;
    private readonly DispatcherQueue dispatcher;
    private readonly CancellationTokenSource lifetime = new();
    private Task? serverTask;

    public NamedPipeRecorderControlServer(RecordingViewModel viewModel, DispatcherQueue dispatcher)
    {
        this.viewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        this.dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
    }

    public void Start()
    {
        if (serverTask is not null) return;
        serverTask = RunAsync(lifetime.Token);
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            await using var pipe = new NamedPipeServerStream(
                RecorderControlProtocol.PipeName(),
                PipeDirection.InOut,
                1,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly,
                4096,
                4096);
            try
            {
                await pipe.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                using var requestLifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                requestLifetime.CancelAfter(TimeSpan.FromSeconds(5));
                await HandleConnectionAsync(pipe, requestLifetime.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (OperationCanceledException)
            {
                // A same-user client that connects but does not finish one bounded request
                // must not monopolize the single control server instance.
            }
            catch (IOException)
            {
                // A client can disappear at any point. Keep the local control plane available.
            }
        }
    }

    private async Task HandleConnectionAsync(Stream stream, CancellationToken cancellationToken)
    {
        RecorderControlResponse response;
        string requestId = "invalid";
        try
        {
            var payload = await ReadBoundedLineAsync(stream, RecorderControlProtocol.MaxRequestBytes, cancellationToken)
                .ConfigureAwait(false);
            var request = RecorderControlProtocol.DeserializeRequest(payload)
                ?? throw new RecorderControlException("invalid_request", "The request body is empty.");
            requestId = request.RequestId ?? "invalid";
            var result = await InvokeOnUiThreadAsync(() => viewModel.ExecuteControlRequestAsync(request), cancellationToken)
                .ConfigureAwait(false);
            response = RecorderControlResponse.Success(requestId, result);
        }
        catch (RecorderControlException exception)
        {
            response = RecorderControlResponse.Failure(requestId, exception.Code, exception.Message);
        }
        catch (JsonException)
        {
            response = RecorderControlResponse.Failure(requestId, "invalid_json", "The request is not valid control JSON.");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }
        catch (Exception)
        {
            response = RecorderControlResponse.Failure(requestId, "internal", "The recorder could not complete the command.");
        }

        var bytes = JsonSerializer.SerializeToUtf8Bytes(response, JsonOptions);
        if (bytes.Length > RecorderControlProtocol.MaxResponseBytes)
        {
            bytes = JsonSerializer.SerializeToUtf8Bytes(
                RecorderControlResponse.Failure(requestId, "response_too_large", "The response exceeded the control protocol limit."),
                JsonOptions);
        }
        await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync("\n"u8.ToArray(), cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private Task<RecorderControlStatus> InvokeOnUiThreadAsync(
        Func<Task<RecorderControlStatus>> operation,
        CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<RecorderControlStatus>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!dispatcher.TryEnqueue(async () =>
            {
                try { completion.TrySetResult(await operation()); }
                catch (Exception exception) { completion.TrySetException(exception); }
            }))
        {
            throw new RecorderControlException("not_ready", "The recorder UI dispatcher is unavailable.");
        }
        return completion.Task.WaitAsync(TimeSpan.FromSeconds(15), cancellationToken);
    }

    internal static async Task<byte[]> ReadBoundedLineAsync(Stream stream, int maxBytes, CancellationToken cancellationToken)
    {
        if (maxBytes <= 0) throw new ArgumentOutOfRangeException(nameof(maxBytes));
        using var buffer = new MemoryStream(Math.Min(maxBytes, 4096));
        var single = new byte[1];
        while (buffer.Length <= maxBytes)
        {
            var count = await stream.ReadAsync(single, cancellationToken).ConfigureAwait(false);
            if (count == 0) throw new RecorderControlException("invalid_request", "The control client closed before sending a request.");
            if (single[0] == (byte)'\n') return buffer.ToArray();
            buffer.WriteByte(single[0]);
        }
        throw new RecorderControlException("request_too_large", "The control request exceeded the 8 KiB limit.");
    }

    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        if (serverTask is not null)
        {
            try { await serverTask.ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }
        lifetime.Dispose();
    }
}
