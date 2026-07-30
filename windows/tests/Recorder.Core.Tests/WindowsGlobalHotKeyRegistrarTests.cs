using System.Collections.Concurrent;
using System.ComponentModel;
using TeamsRecorder.Windows.Application;

internal static class WindowsGlobalHotKeyRegistrarTests
{
    public static void RoutesCtrlAltMAndUnregistersExactlyOnce()
    {
        var native = new FakeNativeApi();
        using var registrar = new WindowsGlobalHotKeyRegistrar(native);
        using var registration = registrar.RegisterCtrlAltM();
        using var pressed = new ManualResetEventSlim();
        var count = 0;
        registration.Pressed += (_, _) => { Interlocked.Increment(ref count); pressed.Set(); };
        native.SendHotKey(1);
        if (!pressed.Wait(TimeSpan.FromSeconds(2))) throw new InvalidOperationException("The hotkey message was not routed.");
        if (count != 1) throw new InvalidOperationException("The hotkey should raise exactly one event.");
        registration.Dispose();
        registration.Dispose();
        if (native.UnregisterCalls != 1) throw new InvalidOperationException("Disposal must unregister once.");
        native.SendHotKey(1);
        Thread.Sleep(50);
        if (count != 1) throw new InvalidOperationException("An unregistered hotkey must not raise an event.");
    }

    public static void FailsWithWin32ErrorWhenCtrlAltMIsUnavailable()
    {
        var native = new FakeNativeApi { RegisterSucceeds = false, LastError = 1409 };
        using var registrar = new WindowsGlobalHotKeyRegistrar(native);
        var error = Throws<Win32Exception>(() => registrar.RegisterCtrlAltM());
        if (error.NativeErrorCode != 1409) throw new InvalidOperationException("The native registration failure was not preserved.");

        ReportsMessageLoopFailureWithoutBlocking();
    }

    private static void ReportsMessageLoopFailureWithoutBlocking()
    {
        var native = new FakeNativeApi { FailNextGetMessage = true, LastError = 6 };
        using var registrar = new WindowsGlobalHotKeyRegistrar(native);
        native.WaitForLoopFailure();

        var error = Throws<InvalidOperationException>(() => registrar.RegisterCtrlAltM());
        if (error.InnerException is not Win32Exception { NativeErrorCode: 6 })
            throw new InvalidOperationException("The message-loop failure was not preserved.");
    }

    private static T Throws<T>(Action action) where T : Exception
    {
        try { action(); } catch (T error) { return error; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private sealed class FakeNativeApi : IWindowsHotKeyNativeApi
    {
        private const uint WmQuit = 0x0012;
        private readonly BlockingCollection<WindowsHotKeyMessage> messages = new();
        private readonly ManualResetEventSlim loopFailed = new();
        public bool RegisterSucceeds { get; set; } = true;
        public bool FailNextGetMessage { get; set; }
        public int LastError { get; set; }
        public int UnregisterCalls { get; private set; }
        public uint GetCurrentThreadId() => 1;
        public void EnsureMessageQueue() { }
        public bool RegisterHotKey(int id, uint modifiers, uint virtualKey) => RegisterSucceeds;
        public bool UnregisterHotKey(int id) { UnregisterCalls++; return true; }
        public bool PostThreadMessage(uint threadId, uint message, nuint wParam, nint lParam) { messages.Add(new WindowsHotKeyMessage(message, wParam)); return true; }
        public int GetMessage(out WindowsHotKeyMessage message)
        {
            if (FailNextGetMessage)
            {
                FailNextGetMessage = false;
                loopFailed.Set();
                message = default;
                return -1;
            }
            message = messages.Take();
            return message.Message == WmQuit ? 0 : 1;
        }
        public int GetLastError() => LastError;
        public void SendHotKey(int id) => messages.Add(new WindowsHotKeyMessage(0x0312, (nuint)id));
        public void WaitForLoopFailure()
        {
            if (!loopFailed.Wait(TimeSpan.FromSeconds(2)))
                throw new InvalidOperationException("The fake message loop did not fail.");
        }
    }
}
