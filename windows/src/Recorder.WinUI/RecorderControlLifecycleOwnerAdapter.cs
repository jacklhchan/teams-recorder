using Microsoft.UI.Dispatching;
using TeamsRecorder.Windows.Application.Control;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// The small VM-facing control surface deliberately contains only protocol-safe
/// values.  It keeps named-pipe request handling from acquiring any UI object
/// or exposing diagnostics, paths, process IDs, or window handles.
/// </summary>
internal interface IRecorderControlViewModelLifecycle
{
    Task<RecorderControlStatus> GetRecorderControlStatusAsync(CancellationToken cancellationToken);

    Task<RecorderControlActionResult> StartRecorderControlAsync(CancellationToken cancellationToken);

    Task<RecorderControlActionResult> StopRecorderControlAsync(CancellationToken cancellationToken);

    Task<RecorderControlActionResult> SetRecorderControlAutomaticModeAsync(
        bool enabled,
        CancellationToken cancellationToken);

    Task<RecorderControlActionResult> SetRecorderControlMicrophoneMutedAsync(
        bool muted,
        CancellationToken cancellationToken);
}

/// <summary>
/// Marshals each local named-pipe request through the WinUI dispatcher before
/// it reaches the same view-model lifecycle used by buttons and overlay
/// actions.  Cancellation before a queued dispatcher callback executes is
/// fail-closed; once execution starts the VM receives the cancellation token
/// and retains its own lifecycle gate until the operation completes.
/// </summary>
internal sealed class RecorderControlLifecycleOwnerAdapter : IRecorderControlLifecycleOwner, IDisposable
{
    private readonly DispatcherQueue dispatcherQueue;
    private readonly IRecorderControlViewModelLifecycle lifecycle;
    private readonly SemaphoreSlim requestGate = new(1, 1);
    private bool disposed;

    public RecorderControlLifecycleOwnerAdapter(
        DispatcherQueue dispatcherQueue,
        IRecorderControlViewModelLifecycle lifecycle)
    {
        this.dispatcherQueue = dispatcherQueue ?? throw new ArgumentNullException(nameof(dispatcherQueue));
        this.lifecycle = lifecycle ?? throw new ArgumentNullException(nameof(lifecycle));
    }

    public Task<RecorderControlStatus> GetStatusAsync(CancellationToken cancellationToken)
    {
        // Status is an immutable, privacy-safe projection of fields that the
        // view model publishes atomically. Do not marshal this read through
        // the WinUI dispatcher: native discovery or startup recovery may keep
        // that dispatcher busy, and health checks must still distinguish
        // "initializing" from a dead application.
        ThrowIfDisposed();
        return lifecycle.GetRecorderControlStatusAsync(cancellationToken);
    }

    public Task<RecorderControlActionResult> StartAsync(CancellationToken cancellationToken) =>
        InvokeAsync(lifecycle.StartRecorderControlAsync, cancellationToken);

    public Task<RecorderControlActionResult> StopAsync(CancellationToken cancellationToken) =>
        InvokeAsync(lifecycle.StopRecorderControlAsync, cancellationToken);

    public Task<RecorderControlActionResult> SetAutomaticModeAsync(bool enabled, CancellationToken cancellationToken) =>
        InvokeAsync(token => lifecycle.SetRecorderControlAutomaticModeAsync(enabled, token), cancellationToken);

    public Task<RecorderControlActionResult> SetMicrophoneMutedAsync(bool muted, CancellationToken cancellationToken) =>
        InvokeAsync(token => lifecycle.SetRecorderControlMicrophoneMutedAsync(muted, token), cancellationToken);

    private async Task<T> InvokeAsync<T>(
        Func<CancellationToken, Task<T>> operation,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        await requestGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            return await InvokeOnDispatcherAsync(operation, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            requestGate.Release();
        }
    }

    private Task<T> InvokeOnDispatcherAsync<T>(
        Func<CancellationToken, Task<T>> operation,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (dispatcherQueue.HasThreadAccess)
        {
            return operation(cancellationToken);
        }

        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = 0;
        var cancellation = cancellationToken.Register(() =>
        {
            if (Volatile.Read(ref started) == 0)
            {
                completion.TrySetCanceled(cancellationToken);
            }
        });
        _ = completion.Task.ContinueWith(
            _ => cancellation.Dispose(),
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);

        if (!dispatcherQueue.TryEnqueue(async () =>
            {
                if (completion.Task.IsCompleted || Interlocked.Exchange(ref started, 1) != 0)
                {
                    return;
                }

                try
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    completion.TrySetResult(await operation(cancellationToken));
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    completion.TrySetCanceled(cancellationToken);
                }
                catch (Exception exception)
                {
                    completion.TrySetException(exception);
                }
            }))
        {
            completion.TrySetException(new InvalidOperationException("WinUI dispatcher is unavailable."));
        }

        return completion.Task;
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        requestGate.Dispose();
    }

    private void ThrowIfDisposed()
    {
        if (disposed)
        {
            throw new ObjectDisposedException(nameof(RecorderControlLifecycleOwnerAdapter));
        }
    }
}
