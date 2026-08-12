using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

/// <summary>Registers application-wide Windows shortcuts on a dedicated native message-loop thread.</summary>
public sealed class WindowsGlobalHotKeyRegistrar : IGlobalHotKeyRegistrar, IDisposable
{
    private const uint WmHotKey = 0x0312;
    private const uint WmWork = 0x8001;
    private const uint CtrlAlt = 0x0003;
    private const uint VirtualKeyM = 0x4D;
    private readonly object gate = new();
    private readonly IWindowsHotKeyNativeApi native;
    private readonly object loopGate = new();
    private readonly Queue<LoopWorkItem> pendingWork = new();
    private readonly Dictionary<int, Registration> registrations = new();
    private readonly Thread loopThread;
    private readonly TaskCompletionSource loopReady = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private uint loopThreadId;
    private int nextRegistrationId;
    private bool disposed;
    private bool loopStopped;
    private Exception? loopFailure;

    [SupportedOSPlatform("windows")]
    public WindowsGlobalHotKeyRegistrar() : this(new User32HotKeyNativeApi()) { }

    /// <summary>Injects the native boundary; intended for deterministic host tests.</summary>
    public WindowsGlobalHotKeyRegistrar(IWindowsHotKeyNativeApi native)
    {
        this.native = native ?? throw new ArgumentNullException(nameof(native));
        loopThread = new Thread(RunMessageLoop) { IsBackground = true, Name = "Recorder global hotkey message loop" };
        loopThread.Start();
        loopReady.Task.GetAwaiter().GetResult();
    }

    public IGlobalHotKeyRegistration RegisterCtrlAltM()
    {
        lock (gate)
        {
            ThrowIfDisposed();
            Registration? registration = null;
            InvokeOnLoop(() =>
            {
                var id = checked(++nextRegistrationId);
                if (!native.RegisterHotKey(id, CtrlAlt, VirtualKeyM))
                    throw new Win32Exception(native.GetLastError(), "Windows could not register the Ctrl+Alt+M global hotkey.");
                registration = new Registration(this, id);
                registrations.Add(id, registration);
            });
            return registration!;
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
        }
        try
        {
            InvokeOnLoop(UnregisterAll);
        }
        catch (Exception)
        {
            // A dead native message loop cannot unregister thread-bound hotkeys. They are
            // released by Windows when that thread terminates; disposal must still finish.
        }

        lock (loopGate)
        {
            if (!loopStopped)
                native.PostThreadMessage(loopThreadId, 0x0012, 0, 0); // WM_QUIT
        }

        if (Environment.CurrentManagedThreadId != loopThread.ManagedThreadId)
            loopThread.Join(TimeSpan.FromSeconds(2));
    }

    private void RunMessageLoop()
    {
        try
        {
            loopThreadId = native.GetCurrentThreadId();
            native.EnsureMessageQueue();
            loopReady.TrySetResult();
            int result;
            while ((result = native.GetMessage(out var message)) > 0)
            {
                if (message.Message == WmWork)
                {
                    DrainWork();
                }
                else if (message.Message == WmHotKey && registrations.TryGetValue((int)message.WParam, out var registration))
                {
                    registration.RaisePressed();
                }
            }
            if (result < 0)
                throw new Win32Exception(native.GetLastError(), "Windows could not read from the global hotkey message loop.");
        }
        catch (Exception error)
        {
            loopReady.TrySetException(error);
            StopLoop(error);
        }
        finally
        {
            StopLoop(loopFailure ?? new InvalidOperationException("The Windows global hotkey message loop stopped unexpectedly."));
        }
    }

    private void InvokeOnLoop(Action action)
    {
        if (Environment.CurrentManagedThreadId == loopThread.ManagedThreadId)
        {
            ThrowIfLoopStopped();
            action();
            return;
        }

        var work = new LoopWorkItem(action);
        lock (loopGate)
        {
            ThrowIfLoopStopped();
            pendingWork.Enqueue(work);
            if (!native.PostThreadMessage(loopThreadId, WmWork, 0, 0))
            {
                var error = new Win32Exception(native.GetLastError(), "Windows could not wake the global hotkey message loop.");
                work.Fail(error);
                throw error;
            }
        }
        work.Wait();
    }

    private void DrainWork()
    {
        while (true)
        {
            LoopWorkItem? work;
            lock (loopGate)
            {
                if (pendingWork.Count == 0) return;
                work = pendingWork.Dequeue();
            }
            work.Execute();
        }
    }

    private void StopLoop(Exception error)
    {
        LoopWorkItem[] work;
        lock (loopGate)
        {
            if (loopStopped) return;
            loopStopped = true;
            loopFailure = error;
            work = pendingWork.ToArray();
            pendingWork.Clear();
        }
        foreach (var item in work) item.Fail(error);
    }

    private void ThrowIfLoopStopped()
    {
        if (!loopStopped) return;
        throw new InvalidOperationException("The Windows global hotkey message loop is not available.", loopFailure);
    }

    private void Unregister(Registration registration)
    {
        lock (gate) { if (disposed) return; }
        InvokeOnLoop(() => { if (registrations.Remove(registration.Id)) native.UnregisterHotKey(registration.Id); });
    }

    private void UnregisterAll()
    {
        foreach (var id in registrations.Keys.ToArray()) { native.UnregisterHotKey(id); registrations.Remove(id); }
    }

    private void ThrowIfDisposed()
    {
        if (disposed) throw new ObjectDisposedException(nameof(WindowsGlobalHotKeyRegistrar));
    }

    private sealed class Registration : IGlobalHotKeyRegistration
    {
        private WindowsGlobalHotKeyRegistrar? owner;
        public Registration(WindowsGlobalHotKeyRegistrar owner, int id) => (this.owner, Id) = (owner, id);
        public int Id { get; }
        public event EventHandler? Pressed;
        public void Dispose() => Interlocked.Exchange(ref owner, null)?.Unregister(this);
        public void RaisePressed() => Pressed?.Invoke(this, EventArgs.Empty);
    }

    private sealed class LoopWorkItem
    {
        private readonly Action action;
        private readonly TaskCompletionSource completion = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public LoopWorkItem(Action action) => this.action = action;

        public void Execute()
        {
            if (completion.Task.IsCompleted) return;
            try { action(); completion.TrySetResult(); }
            catch (Exception error) { completion.TrySetException(error); }
        }

        public void Fail(Exception error) => completion.TrySetException(error);
        public void Wait() => completion.Task.GetAwaiter().GetResult();
    }
}

/// <summary>Minimal User32 boundary, kept public so the registrar can be host-tested without Windows.</summary>
public interface IWindowsHotKeyNativeApi
{
    uint GetCurrentThreadId();
    void EnsureMessageQueue();
    bool RegisterHotKey(int id, uint modifiers, uint virtualKey);
    bool UnregisterHotKey(int id);
    bool PostThreadMessage(uint threadId, uint message, nuint wParam, nint lParam);
    int GetMessage(out WindowsHotKeyMessage message);
    int GetLastError();
}

public readonly record struct WindowsHotKeyMessage(uint Message, nuint WParam);

[SupportedOSPlatform("windows")]
internal sealed partial class User32HotKeyNativeApi : IWindowsHotKeyNativeApi
{
    public uint GetCurrentThreadId() => GetCurrentThreadIdNative();
    public void EnsureMessageQueue() => PeekMessage(out _, 0, 0, 0, 0);
    public bool RegisterHotKey(int id, uint modifiers, uint virtualKey) => RegisterHotKeyNative(0, id, modifiers, virtualKey);
    public bool UnregisterHotKey(int id) => UnregisterHotKeyNative(0, id);
    public bool PostThreadMessage(uint threadId, uint message, nuint wParam, nint lParam) => PostThreadMessageNative(threadId, message, wParam, lParam);
    public int GetMessage(out WindowsHotKeyMessage message)
    {
        var result = GetMessageNative(out var nativeMessage, 0, 0, 0);
        message = new WindowsHotKeyMessage(nativeMessage.message, nativeMessage.wParam);
        return result;
    }
    public int GetLastError() => Marshal.GetLastWin32Error();

    [LibraryImport("kernel32.dll", EntryPoint = "GetCurrentThreadId", SetLastError = false)] private static partial uint GetCurrentThreadIdNative();
    [LibraryImport("user32.dll", EntryPoint = "RegisterHotKey", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool RegisterHotKeyNative(nint hWnd, int id, uint modifiers, uint virtualKey);
    [LibraryImport("user32.dll", EntryPoint = "UnregisterHotKey", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool UnregisterHotKeyNative(nint hWnd, int id);
    [LibraryImport("user32.dll", EntryPoint = "PostThreadMessageW", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool PostThreadMessageNative(uint threadId, uint message, nuint wParam, nint lParam);
    [LibraryImport("user32.dll", EntryPoint = "GetMessageW", SetLastError = true)] private static partial int GetMessageNative(out NativeMessage message, nint hWnd, uint minFilter, uint maxFilter);
    [LibraryImport("user32.dll", EntryPoint = "PeekMessageW", SetLastError = false)] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool PeekMessage(out NativeMessage message, nint hWnd, uint minFilter, uint maxFilter, uint removeMessage);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeMessage
    {
        public nint hWnd;
        public uint message;
        public nuint wParam;
        public nint lParam;
        public uint time;
        public nint pointX;
        public nint pointY;
        public uint lPrivate;
    }
}
