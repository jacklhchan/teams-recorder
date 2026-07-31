using System.Runtime.InteropServices;
using WinRT.Interop;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Owns the notification-area icon for the lifetime of the primary window.
/// The icon is implemented with the Windows shell API so the unpackaged build
/// does not need an additional UI dependency.
/// </summary>
internal sealed class TrayIconService : IDisposable
{
    private const int GwlWndProc = -4;
    private const uint WmApp = 0x8000;
    private const uint TrayCallbackMessage = WmApp + 41;
    private const uint WmLButtonUp = 0x0202;
    private const uint WmRButtonUp = 0x0205;
    private const uint NifMessage = 0x00000001;
    private const uint NifIcon = 0x00000002;
    private const uint NifTip = 0x00000004;
    private const uint NimAdd = 0x00000000;
    private const uint NimDelete = 0x00000002;
    private const uint NimSetVersion = 0x00000004;
    private const uint NotifyIconVersion4 = 4;
    private const uint TpmRightButton = 0x0002;
    private const uint TpmReturnCommand = 0x0100;
    private const uint MfString = 0x0000;
    private const uint MfSeparator = 0x0800;
    private const uint SwHide = 0;
    private const uint SwRestore = 9;
    private const uint ImageIcon = 1;
    private const uint LrLoadFromFile = 0x0010;
    private const uint LrDefaultSize = 0x0040;
    private const int IdiApplication = 32512;
    private const uint MenuShow = 1;
    private const uint MenuHide = 2;
    private const uint MenuExit = 3;

    private readonly nint hwnd;
    private readonly Action show;
    private readonly Action hide;
    private readonly Action exit;
    private readonly WindowProcedure windowProcedure;
    private readonly nint previousWindowProcedure;
    private nint icon;
    private bool ownsIcon;
    private bool disposed;

    public TrayIconService(Microsoft.UI.Xaml.Window window, Action show, Action hide, Action exit)
    {
        ArgumentNullException.ThrowIfNull(window);
        this.show = show ?? throw new ArgumentNullException(nameof(show));
        this.hide = hide ?? throw new ArgumentNullException(nameof(hide));
        this.exit = exit ?? throw new ArgumentNullException(nameof(exit));
        hwnd = WindowNative.GetWindowHandle(window);

        windowProcedure = WindowProcedureImpl;
        previousWindowProcedure = SetWindowLongPtr(hwnd, GwlWndProc, Marshal.GetFunctionPointerForDelegate(windowProcedure));
        AddIcon();
    }

    public void HideWindow() => _ = ShowWindow(hwnd, SwHide);

    public void ShowWindow()
    {
        _ = ShowWindow(hwnd, SwRestore);
        _ = SetForegroundWindow(hwnd);
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        _ = ShellNotifyIcon(NimDelete, CreateNotifyIconData());
        _ = SetWindowLongPtr(hwnd, GwlWndProc, previousWindowProcedure);
        if (ownsIcon && icon != nint.Zero)
        {
            _ = DestroyIcon(icon);
        }
    }

    private nint WindowProcedureImpl(nint hWnd, uint message, nint wParam, nint lParam)
    {
        if (message == TrayCallbackMessage)
        {
            var notification = unchecked((uint)lParam.ToInt64());
            if (notification == WmLButtonUp)
            {
                show();
                return nint.Zero;
            }

            if (notification == WmRButtonUp)
            {
                ShowContextMenu();
                return nint.Zero;
            }
        }

        return CallWindowProc(previousWindowProcedure, hWnd, message, wParam, lParam);
    }

    private void AddIcon()
    {
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
        icon = LoadImage(nint.Zero, iconPath, ImageIcon, 0, 0, LrLoadFromFile | LrDefaultSize);
        ownsIcon = icon != nint.Zero;
        if (icon == nint.Zero)
        {
            icon = LoadIcon(nint.Zero, (nint)IdiApplication);
        }

        var data = CreateNotifyIconData();
        _ = ShellNotifyIcon(NimAdd, data);
        data.uVersion = NotifyIconVersion4;
        _ = ShellNotifyIcon(NimSetVersion, data);
    }

    private NotifyIconData CreateNotifyIconData() => new()
    {
        cbSize = (uint)Marshal.SizeOf<NotifyIconData>(),
        hWnd = hwnd,
        uID = 1,
        uFlags = NifMessage | NifIcon | NifTip,
        uCallbackMessage = TrayCallbackMessage,
        hIcon = icon,
        szTip = "Teams Recorder",
    };

    private void ShowContextMenu()
    {
        var menu = CreatePopupMenu();
        if (menu == nint.Zero)
        {
            return;
        }

        try
        {
            _ = AppendMenu(menu, MfString, MenuShow, "顯示 Teams Recorder");
            _ = AppendMenu(menu, MfString, MenuHide, "隱藏視窗");
            _ = AppendMenu(menu, MfSeparator, 0, null);
            _ = AppendMenu(menu, MfString, MenuExit, "結束 Teams Recorder");
            _ = GetCursorPos(out var position);
            _ = SetForegroundWindow(hwnd);
            var command = TrackPopupMenu(menu, TpmRightButton | TpmReturnCommand, position.X, position.Y, 0, hwnd, nint.Zero);
            switch (command)
            {
                case MenuShow:
                    show();
                    break;
                case MenuHide:
                    hide();
                    break;
                case MenuExit:
                    exit();
                    break;
            }
        }
        finally
        {
            _ = DestroyMenu(menu);
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate nint WindowProcedure(nint hWnd, uint message, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint cbSize;
        public nint hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public nint hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uTimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public nint hBalloonIcon;

        public uint uVersion { set => uTimeoutOrVersion = value; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShellNotifyIcon(uint dwMessage, NotifyIconData lpData);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint LoadImage(nint hInst, string name, uint type, int cx, int cy, uint fuLoad);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint LoadIcon(nint hInstance, nint lpIconName);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(nint hIcon);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetWindowLongPtr(nint hWnd, int nIndex, nint dwNewLong);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint CallWindowProc(nint lpPrevWndFunc, nint hWnd, uint msg, nint wParam, nint lParam);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(nint hWnd, uint nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point lpPoint);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenu(nint hMenu, uint uFlags, uint uIDNewItem, string? lpNewItem);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint TrackPopupMenu(nint hMenu, uint uFlags, int x, int y, int nReserved, nint hWnd, nint prcRect);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(nint hMenu);
}
