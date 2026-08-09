using System.Diagnostics;
using System.Runtime.InteropServices;
using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

/// <summary>
/// Supplies an already-filtered local Teams meeting inventory.  The result
/// contains only transient runtime identities and is never a persistence or
/// telemetry contract.
/// </summary>
public interface ITeamsLocalWindowInventory
{
    TeamsLocalMeetingObservation Inspect();
}

/// <summary>
/// A signal-only WinEvent boundary.  It deliberately does not publish HWND,
/// PID, title, or process information; consumers re-enumerate and validate
/// everything after a debounced signal.
/// </summary>
public interface ITeamsWindowChangeSource : IDisposable
{
    event EventHandler? Changed;
    void Start();
    void Stop();
}

public interface ITeamsLocalMeetingClock
{
    DateTimeOffset UtcNow { get; }
    Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken);
}

public sealed class SystemTeamsLocalMeetingClock : ITeamsLocalMeetingClock
{
    public DateTimeOffset UtcNow => DateTimeOffset.UtcNow;

    public Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken) =>
        Task.Delay(delay, cancellationToken);
}

public sealed record TeamsLocalMeetingMonitorOptions
{
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(1);
    public TimeSpan EventDebounce { get; init; } = TimeSpan.FromMilliseconds(250);

    public void Validate()
    {
        if (PollInterval < TimeSpan.FromMilliseconds(250) ||
            PollInterval > TimeSpan.FromSeconds(10))
        {
            throw new ArgumentOutOfRangeException(nameof(PollInterval));
        }

        if (EventDebounce < TimeSpan.Zero || EventDebounce > TimeSpan.FromSeconds(5))
        {
            throw new ArgumentOutOfRangeException(nameof(EventDebounce));
        }
    }
}

/// <summary>
/// Combines low-latency WinEvent invalidation with a bounded polling fallback.
/// A burst of UI events schedules only one re-inventory after EventDebounce;
/// polling remains bounded to 250 ms..10 s and the pure Core detector applies a
/// second observation-spacing gate.
/// </summary>
public sealed class TeamsLocalMeetingMonitor : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly SemaphoreSlim refreshGate = new(1, 1);
    private readonly ITeamsLocalWindowInventory inventory;
    private readonly ITeamsWindowChangeSource changes;
    private readonly ITeamsLocalMeetingClock clock;
    private readonly TeamsLocalMeetingMonitorOptions options;
    private readonly TeamsLocalMeetingDetector detector;
    private CancellationTokenSource? lifetime;
    private Task? pollingTask;
    private Task? eventRefreshTask;
    private long generation;
    private bool disposed;

    public TeamsLocalMeetingMonitor(
        ITeamsLocalWindowInventory inventory,
        ITeamsWindowChangeSource changes,
        TeamsLocalMeetingDetector? detector = null,
        ITeamsLocalMeetingClock? clock = null,
        TeamsLocalMeetingMonitorOptions? options = null)
    {
        this.inventory = inventory ?? throw new ArgumentNullException(nameof(inventory));
        this.changes = changes ?? throw new ArgumentNullException(nameof(changes));
        this.detector = detector ?? new TeamsLocalMeetingDetector();
        this.clock = clock ?? new SystemTeamsLocalMeetingClock();
        this.options = options ?? new TeamsLocalMeetingMonitorOptions();
        this.options.Validate();
    }

    public event EventHandler<TeamsLocalMeetingDetectionUpdate>? DetectionChanged;

    public TeamsLocalMeetingDetectionSnapshot Snapshot
    {
        get { lock (gate) return detector.Snapshot; }
    }

    /// <summary>
    /// Runtime-only identity for the immediate UIA operation.  It must not be
    /// copied into view-model persistence, diagnostics, or IPC status.
    /// </summary>
    public TeamsWindowIdentity? ActiveIdentity
    {
        get { lock (gate) return detector.ActiveIdentity; }
    }

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        CancellationTokenSource source;
        lock (gate)
        {
            if (lifetime is not null)
            {
                return;
            }

            source = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            lifetime = source;
            generation++;
            changes.Changed += OnWindowChanged;
        }

        try
        {
            changes.Start();
            await RefreshNowAsync(source.Token).ConfigureAwait(false);
            lock (gate)
            {
                if (ReferenceEquals(lifetime, source))
                {
                    pollingTask = PollAsync(generation, source.Token);
                }
            }
        }
        catch
        {
            await StopCoreAsync(source).ConfigureAwait(false);
            throw;
        }
    }

    /// <summary>
    /// Performs exactly one inventory/identity validation.  It is public for
    /// deterministic tests and for an explicit user refresh; normal callers use
    /// StartAsync plus WinEvent/polling.
    /// </summary>
    public async Task RefreshNowAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await refreshGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        TeamsLocalMeetingDetectionUpdate update;
        TeamsLocalMeetingDetectionSnapshot before;
        try
        {
            TeamsLocalMeetingObservation observation;
            try
            {
                observation = inventory.Inspect() ?? TeamsLocalMeetingObservation.Unavailable;
            }
            catch (Exception)
            {
                // Native/UIA failures can include user content in an exception
                // message.  Project a privacy-safe Unavailable status instead.
                observation = TeamsLocalMeetingObservation.Unavailable;
            }

            lock (gate)
            {
                before = detector.Snapshot;
                update = detector.Observe(observation, clock.UtcNow);
            }
        }
        finally
        {
            refreshGate.Release();
        }

        // Do not publish repetitive state snapshots.  A transition may be false
        // even when the visual state happens to match a prior value, so keep it.
        if (update.MeetingPresenceChanged is not null || update.Snapshot != before)
        {
            DetectionChanged?.Invoke(this, update);
        }
        else
        {
            // Snapshot may be equal to the already-current value after a jitter
            // signal.  No event is emitted, which is the de-duplication contract.
        }
    }

    public async Task StopAsync()
    {
        CancellationTokenSource? source;
        lock (gate)
        {
            source = lifetime;
        }

        if (source is null)
        {
            return;
        }

        await StopCoreAsync(source).ConfigureAwait(false);
    }

    private async Task StopCoreAsync(CancellationTokenSource source)
    {
        Task? polling;
        Task? pendingEventRefresh;
        TeamsLocalMeetingDetectionUpdate? reset = null;
        lock (gate)
        {
            if (!ReferenceEquals(lifetime, source))
            {
                return;
            }

            lifetime = null;
            generation++;
            changes.Changed -= OnWindowChanged;
            source.Cancel();
            polling = pollingTask;
            pendingEventRefresh = eventRefreshTask;
            pollingTask = null;
            eventRefreshTask = null;
            reset = detector.Reset();
        }

        try { changes.Stop(); } catch { /* no raw platform diagnostics here */ }
        await AwaitWithoutSelfAsync(polling).ConfigureAwait(false);
        await AwaitWithoutSelfAsync(pendingEventRefresh).ConfigureAwait(false);
        source.Dispose();

        if (reset.MeetingPresenceChanged is not null)
        {
            DetectionChanged?.Invoke(this, reset);
        }
    }

    private async Task PollAsync(long expectedGeneration, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await clock.DelayAsync(options.PollInterval, cancellationToken).ConfigureAwait(false);
                lock (gate)
                {
                    if (generation != expectedGeneration || lifetime is null || lifetime.Token != cancellationToken)
                    {
                        return;
                    }
                }
                await RefreshNowAsync(cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (ObjectDisposedException) when (disposed)
        {
        }
    }

    private void OnWindowChanged(object? sender, EventArgs args)
    {
        CancellationToken cancellationToken;
        long expectedGeneration;
        lock (gate)
        {
            if (lifetime is null || eventRefreshTask is not null)
            {
                return;
            }

            cancellationToken = lifetime.Token;
            expectedGeneration = generation;
            eventRefreshTask = DebouncedEventRefreshAsync(expectedGeneration, cancellationToken);
        }
    }

    private async Task DebouncedEventRefreshAsync(long expectedGeneration, CancellationToken cancellationToken)
    {
        try
        {
            if (options.EventDebounce > TimeSpan.Zero)
            {
                await clock.DelayAsync(options.EventDebounce, cancellationToken).ConfigureAwait(false);
            }

            lock (gate)
            {
                if (generation != expectedGeneration || lifetime is null)
                {
                    return;
                }
            }
            await RefreshNowAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (ObjectDisposedException) when (disposed)
        {
        }
        finally
        {
            lock (gate)
            {
                // A Stop/Start creates a new generation.  Do not clear the
                // debounce task owned by that newer monitor lifetime.
                if (generation == expectedGeneration)
                {
                    eventRefreshTask = null;
                }
            }
        }
    }

    private static async Task AwaitWithoutSelfAsync(Task? task)
    {
        if (task is null || task.IsCompleted)
        {
            return;
        }

        try { await task.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        await StopAsync().ConfigureAwait(false);
        changes.Dispose();
        refreshGate.Dispose();
    }

    private void ThrowIfDisposed()
    {
        if (disposed)
        {
            throw new ObjectDisposedException(nameof(TeamsLocalMeetingMonitor));
        }
    }
}

/// <summary>
/// Captures only signal classes useful for top-level-window re-enumeration.
/// The callback does not retain or emit the HWND/PID that triggered it.
/// </summary>
public sealed class WindowsTeamsWindowChangeSource : ITeamsWindowChangeSource
{
    private const uint EventSystemForeground = 0x0003;
    private const uint EventObjectCreate = 0x8000;
    private const uint EventObjectLocationChange = 0x800B;
    private const int ObjidWindow = 0;
    private const int ChildIdSelf = 0;
    private const uint WineventOutOfContext = 0;
    private const uint WineventSkipOwnProcess = 0x0002;

    private readonly object gate = new();
    private readonly WinEventDelegate callback;
    private readonly List<nint> hooks = [];
    private bool started;
    private bool disposed;

    public WindowsTeamsWindowChangeSource() => callback = OnWinEvent;

    public event EventHandler? Changed;

    public void Start()
    {
        ThrowIfDisposed();
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        lock (gate)
        {
            if (started)
            {
                return;
            }

            var foreground = SetWinEventHook(
                EventSystemForeground,
                EventSystemForeground,
                nint.Zero,
                callback,
                0,
                0,
                WineventOutOfContext | WineventSkipOwnProcess);
            var windowObjects = SetWinEventHook(
                EventObjectCreate,
                EventObjectLocationChange,
                nint.Zero,
                callback,
                0,
                0,
                WineventOutOfContext | WineventSkipOwnProcess);

            if (foreground != nint.Zero) hooks.Add(foreground);
            if (windowObjects != nint.Zero) hooks.Add(windowObjects);
            started = true;
        }
    }

    public void Stop()
    {
        lock (gate)
        {
            if (!started)
            {
                return;
            }

            foreach (var hook in hooks)
            {
                _ = UnhookWinEvent(hook);
            }
            hooks.Clear();
            started = false;
        }
    }

    private void OnWinEvent(
        nint hook,
        uint eventType,
        nint window,
        int objectId,
        int childId,
        uint eventThread,
        uint eventTime)
    {
        // Foreground has OBJID_WINDOW semantics on supported Windows releases;
        // object events need the explicit filter to ignore child controls.
        if (window == nint.Zero ||
            (eventType != EventSystemForeground &&
             (objectId != ObjidWindow || childId != ChildIdSelf)))
        {
            return;
        }

        try { Changed?.Invoke(this, EventArgs.Empty); }
        catch { /* A subscriber cannot be allowed to destabilize the WinEvent callback. */ }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        Stop();
        GC.SuppressFinalize(this);
    }

    private void ThrowIfDisposed()
    {
        if (disposed)
        {
            throw new ObjectDisposedException(nameof(WindowsTeamsWindowChangeSource));
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void WinEventDelegate(
        nint hook,
        uint eventType,
        nint window,
        int objectId,
        int childId,
        uint eventThread,
        uint eventTime);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetWinEventHook(
        uint eventMin,
        uint eventMax,
        nint module,
        WinEventDelegate callback,
        uint processId,
        uint threadId,
        uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWinEvent(nint hook);
}

public enum TeamsMeetingSurfaceEvidence
{
    Confirmed,
    NotMeeting,
    Unavailable,
}

/// <summary>Proves meeting-surface semantics without window-title matching.</summary>
public interface ITeamsMeetingSurfaceEvidenceProbe
{
    TeamsMeetingSurfaceEvidence Probe(TeamsWindowIdentity identity);
}

/// <summary>
/// Admission is deliberately stricter than a process-name picker.  It uses no
/// title or user content and rejects anything other than a visible, normal,
/// same-integrity Microsoft Teams top-level window.
/// </summary>
public static class TeamsLocalMeetingWindowAdmission
{
    public static TeamsLocalMeetingWindow? TryCreate(VideoCaptureTargetCandidate candidate)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        if (candidate.ProcessId <= 0 || candidate.WindowHandle == nint.Zero ||
            candidate.ProcessCreationTimeFileTimeUtc <= 0 || !candidate.IsTopLevel ||
            !candidate.IsVisible || candidate.IsCloaked || candidate.IsCaptureProtected ||
            candidate.IsHigherIntegrity || candidate.Width <= 0 || candidate.Height <= 0 ||
            !WindowsExecutableBasename.TryCreateExecutableBasename(candidate.ProcessName, out var executable) ||
            !string.Equals(executable, "ms-teams.exe", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return new TeamsLocalMeetingWindow(new TeamsWindowIdentity(
            candidate.ProcessId,
            candidate.WindowHandle,
            candidate.ProcessCreationTimeFileTimeUtc));
    }
}

/// <summary>
/// Converts the existing safe native top-level-window inventory to the local
/// meeting contract.  A UIA evidence failure returns Unavailable rather than a
/// false "no meeting" result, which avoids ending an active recording because
/// an accessibility provider transiently failed.
/// </summary>
public sealed class WindowsTeamsLocalWindowInventory : ITeamsLocalWindowInventory
{
    private const int MaximumNativeCandidates = 512;
    private readonly IVideoCaptureWindowSnapshotProvider windows;
    private readonly ITeamsMeetingSurfaceEvidenceProbe evidence;

    public WindowsTeamsLocalWindowInventory()
        : this(new WindowsVideoCaptureWindowSnapshotProvider(), new WindowsTeamsMeetingSurfaceEvidenceProbe())
    {
    }

    public WindowsTeamsLocalWindowInventory(
        IVideoCaptureWindowSnapshotProvider windows,
        ITeamsMeetingSurfaceEvidenceProbe evidence)
    {
        this.windows = windows ?? throw new ArgumentNullException(nameof(windows));
        this.evidence = evidence ?? throw new ArgumentNullException(nameof(evidence));
    }

    public TeamsLocalMeetingObservation Inspect()
    {
        try
        {
            var candidates = windows.ListCandidates();
            if (candidates.Count > MaximumNativeCandidates)
            {
                return TeamsLocalMeetingObservation.Ambiguous;
            }

            var admitted = new List<TeamsLocalMeetingWindow>();
            foreach (var candidate in candidates)
            {
                var window = TeamsLocalMeetingWindowAdmission.TryCreate(candidate);
                if (window is null)
                {
                    continue;
                }

                // Do not infer "meeting" from the caption, browser text, or a
                // process name.  Only a strict UIA meeting-control binding can
                // confirm it.
                var surfaceEvidence = evidence.Probe(window.Identity);
                if (surfaceEvidence == TeamsMeetingSurfaceEvidence.Unavailable)
                {
                    return TeamsLocalMeetingObservation.Unavailable;
                }

                if (surfaceEvidence == TeamsMeetingSurfaceEvidence.Confirmed)
                {
                    admitted.Add(window);
                }
            }

            return TeamsLocalMeetingObservation.Complete(admitted);
        }
        catch (Exception)
        {
            return TeamsLocalMeetingObservation.Unavailable;
        }
    }
}

/// <summary>Re-checks a runtime window identity immediately before UIA work.</summary>
public interface ITeamsWindowIdentityVerifier
{
    bool IsCurrent(TeamsWindowIdentity identity);
}

/// <summary>
/// Verifies process instance + root HWND ownership without reading titles,
/// paths, command lines, credentials, or user content.
/// </summary>
public sealed class WindowsTeamsWindowIdentityVerifier : ITeamsWindowIdentityVerifier
{
    private const int GaRoot = 2;
    private const int GwlStyle = -16;
    private const nint WsChild = 0x40000000;

    public bool IsCurrent(TeamsWindowIdentity identity)
    {
        if (!OperatingSystem.IsWindows() || !identity.IsWellFormed ||
            !IsWindow(identity.WindowHandle) ||
            GetAncestor(identity.WindowHandle, GaRoot) != identity.WindowHandle ||
            !IsWindowVisible(identity.WindowHandle) ||
            (GetWindowLongPtrW(identity.WindowHandle, GwlStyle) & WsChild) != 0)
        {
            return false;
        }

        try
        {
            _ = GetWindowThreadProcessId(identity.WindowHandle, out var ownerPid);
            if (ownerPid != (uint)identity.ProcessId)
            {
                return false;
            }

            using var process = Process.GetProcessById(identity.ProcessId);
            var processCreated = process.StartTime.ToUniversalTime().ToFileTimeUtc();
            return processCreated == identity.ProcessCreationTimeFileTimeUtc &&
                   WindowsExecutableBasename.TryCreateExecutableBasename(process.ProcessName, out var executable) &&
                   string.Equals(executable, "ms-teams.exe", StringComparison.OrdinalIgnoreCase);
        }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (System.ComponentModel.Win32Exception) { return false; }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool IsWindow(nint window);

    [DllImport("user32.dll")]
    private static extern nint GetAncestor(nint window, int flags);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(nint window);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern nint GetWindowLongPtrW(nint window, int index);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(nint window, out uint processId);
}
