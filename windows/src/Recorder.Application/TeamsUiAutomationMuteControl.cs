using System.Reflection;
using Recorder.Core;

namespace TeamsRecorder.Windows.Application;

public enum TeamsLocalMuteState
{
    Unknown,
    Muted,
    Unmuted,
}

/// <summary>
/// Stable, privacy-safe failure codes for UI/IPC.  Exception messages, UI
/// captions, account details, HWNDs, PIDs, and credentials are intentionally
/// not represented here.
/// </summary>
public enum TeamsUiAutomationFailure
{
    None,
    PlatformUnavailable,
    BindingNotConfigured,
    WindowIdentityInvalid,
    ControlNotFound,
    AmbiguousControls,
    ControlRejected,
    StaleElement,
    ActionRejected,
    ConfirmationFailed,
}

public sealed record TeamsUiAutomationMuteResult(
    TeamsLocalMuteState State,
    TeamsUiAutomationFailure Failure)
{
    public bool IsVerified => Failure == TeamsUiAutomationFailure.None &&
                              State is TeamsLocalMuteState.Muted or TeamsLocalMuteState.Unmuted;

    public static TeamsUiAutomationMuteResult Unknown(TeamsUiAutomationFailure failure) =>
        new(TeamsLocalMuteState.Unknown, failure);
}

/// <summary>
/// A product-verified Teams UIA contract.  This accepts an exact automation ID
/// and TogglePattern semantics only.  It never matches a window title, button
/// name, help text, description, screen text, or localized label.
///
/// The default is deliberately disabled until a Teams build has been verified
/// with a human acceptance run.  Guessing an Electron/Teams accessibility name
/// would be less safe than leaving local mute untouched.
/// </summary>
public sealed record TeamsMuteAutomationBinding
{
    public string? AutomationId { get; init; }
    public bool ToggleOnMeansMuted { get; init; } = true;

    public static TeamsMuteAutomationBinding Disabled { get; } = new();

    public bool IsConfigured => !string.IsNullOrWhiteSpace(AutomationId);

    public void Validate()
    {
        if (!IsConfigured)
        {
            return;
        }

        var id = AutomationId!;
        if (id.Length > 128 || id.Any(char.IsControl) || id != id.Trim())
        {
            throw new ArgumentException("Automation IDs must be a bounded, exact non-control identifier.", nameof(AutomationId));
        }
    }
}

/// <summary>
/// A temporary, one-operation UIA element.  Implementations must not retain
/// the element, HWND, PID, title, or credentials after Dispose returns.
/// </summary>
public interface ITeamsUiAutomationControl : IDisposable
{
    TeamsUiAutomationFailure ReadToggleState(out bool isOn);
    TeamsUiAutomationFailure Toggle();
}

/// <summary>Test seam around the Windows UI Automation tree.</summary>
public interface ITeamsUiAutomationBackend
{
    TeamsUiAutomationFailure TryFindExactControl(
        TeamsWindowIdentity identity,
        TeamsMuteAutomationBinding binding,
        out ITeamsUiAutomationControl? control);
}

/// <summary>
/// Implements a strictly-confirmed Teams mute operation.  UIA calls use an
/// identity only for the duration of the call, revalidate before and after, and
/// keep no mutable identity fields.  A stale/rejected element is never a
/// reason to change recorder mute state.
/// </summary>
public interface ITeamsLocalMuteController
{
    TeamsUiAutomationMuteResult Read(TeamsWindowIdentity identity);
    TeamsUiAutomationMuteResult SetMuted(TeamsWindowIdentity identity, bool muted);
}

public sealed class WindowsTeamsMuteAutomation : ITeamsLocalMuteController
{
    private readonly ITeamsWindowIdentityVerifier identityVerifier;
    private readonly ITeamsUiAutomationBackend automation;
    private readonly TeamsMuteAutomationBinding binding;

    public WindowsTeamsMuteAutomation(
        TeamsMuteAutomationBinding? binding = null,
        ITeamsWindowIdentityVerifier? identityVerifier = null,
        ITeamsUiAutomationBackend? automation = null)
    {
        this.binding = binding ?? TeamsMuteAutomationBinding.Disabled;
        this.binding.Validate();
        this.identityVerifier = identityVerifier ?? new WindowsTeamsWindowIdentityVerifier();
        this.automation = automation ?? new ReflectionTeamsUiAutomationBackend();
    }

    public TeamsUiAutomationMuteResult Read(TeamsWindowIdentity identity)
    {
        if (!binding.IsConfigured)
        {
            return TeamsUiAutomationMuteResult.Unknown(TeamsUiAutomationFailure.BindingNotConfigured);
        }

        if (!identityVerifier.IsCurrent(identity))
        {
            return TeamsUiAutomationMuteResult.Unknown(TeamsUiAutomationFailure.WindowIdentityInvalid);
        }

        var find = automation.TryFindExactControl(identity, binding, out var control);
        if (find != TeamsUiAutomationFailure.None || control is null)
        {
            return TeamsUiAutomationMuteResult.Unknown(
                find == TeamsUiAutomationFailure.None
                    ? TeamsUiAutomationFailure.ControlNotFound
                    : find);
        }

        using (control)
        {
            var read = control.ReadToggleState(out var isOn);
            if (read != TeamsUiAutomationFailure.None)
            {
                return TeamsUiAutomationMuteResult.Unknown(read);
            }

            // An element can outlive a destroyed/recycled HWND.  Recheck the
            // process instance and root HWND immediately before trusting it.
            if (!identityVerifier.IsCurrent(identity))
            {
                return TeamsUiAutomationMuteResult.Unknown(TeamsUiAutomationFailure.WindowIdentityInvalid);
            }

            var muted = binding.ToggleOnMeansMuted ? isOn : !isOn;
            return new TeamsUiAutomationMuteResult(
                muted ? TeamsLocalMuteState.Muted : TeamsLocalMuteState.Unmuted,
                TeamsUiAutomationFailure.None);
        }
    }

    public TeamsUiAutomationMuteResult SetMuted(TeamsWindowIdentity identity, bool muted)
    {
        var before = Read(identity);
        if (!before.IsVerified || !identityVerifier.IsCurrent(identity))
        {
            return before.IsVerified
                ? TeamsUiAutomationMuteResult.Unknown(TeamsUiAutomationFailure.WindowIdentityInvalid)
                : before;
        }

        var desired = muted ? TeamsLocalMuteState.Muted : TeamsLocalMuteState.Unmuted;
        if (before.State == desired)
        {
            return before;
        }

        var find = automation.TryFindExactControl(identity, binding, out var control);
        if (find != TeamsUiAutomationFailure.None || control is null)
        {
            return TeamsUiAutomationMuteResult.Unknown(
                find == TeamsUiAutomationFailure.None
                    ? TeamsUiAutomationFailure.ControlNotFound
                    : find);
        }

        using (control)
        {
            // Read again from the operation's fresh UIA element.  Do not turn a
            // stale action into a blind toggle.
            var read = control.ReadToggleState(out var isOn);
            if (read != TeamsUiAutomationFailure.None)
            {
                return TeamsUiAutomationMuteResult.Unknown(read);
            }

            var current = binding.ToggleOnMeansMuted ? isOn : !isOn;
            if (current != muted)
            {
                if (!identityVerifier.IsCurrent(identity))
                {
                    return TeamsUiAutomationMuteResult.Unknown(TeamsUiAutomationFailure.WindowIdentityInvalid);
                }

                var toggle = control.Toggle();
                if (toggle != TeamsUiAutomationFailure.None)
                {
                    return TeamsUiAutomationMuteResult.Unknown(toggle);
                }
            }
        }

        // Confirm using a new lookup.  This catches a removed/rebound element,
        // delayed UI update, rejected invoke, and PID/HWND identity reuse.
        var confirmed = Read(identity);
        return confirmed.IsVerified && confirmed.State == desired
            ? confirmed
            : TeamsUiAutomationMuteResult.Unknown(
                confirmed.IsVerified
                    ? TeamsUiAutomationFailure.ConfirmationFailed
                    : confirmed.Failure);
    }
}

/// <summary>
/// Makes the same exact UIA mute-control contract the proof that a top-level
/// Teams window is a meeting surface.  It avoids all caption/title heuristics.
/// </summary>
public sealed class WindowsTeamsMeetingSurfaceEvidenceProbe : ITeamsMeetingSurfaceEvidenceProbe
{
    private readonly WindowsTeamsMuteAutomation mute;

    public WindowsTeamsMeetingSurfaceEvidenceProbe(
        TeamsMuteAutomationBinding? binding = null,
        ITeamsWindowIdentityVerifier? identityVerifier = null,
        ITeamsUiAutomationBackend? automation = null)
    {
        mute = new WindowsTeamsMuteAutomation(binding, identityVerifier, automation);
    }

    public TeamsMeetingSurfaceEvidence Probe(TeamsWindowIdentity identity)
    {
        var result = mute.Read(identity);
        if (result.IsVerified)
        {
            return TeamsMeetingSurfaceEvidence.Confirmed;
        }

        return result.Failure switch
        {
            TeamsUiAutomationFailure.BindingNotConfigured or
            TeamsUiAutomationFailure.ControlNotFound or
            TeamsUiAutomationFailure.AmbiguousControls or
            TeamsUiAutomationFailure.ControlRejected => TeamsMeetingSurfaceEvidence.NotMeeting,
            _ => TeamsMeetingSurfaceEvidence.Unavailable,
        };
    }
}

/// <summary>
/// Runtime UIA backend kept reflection-based so Recorder.Application remains a
/// portable net10.0 library.  It loads UIAutomationClient only on Windows and
/// uses an exact AutomationId + Button + TogglePattern contract; no Name,
/// title, HelpText, Description, or localized text is ever read.
/// </summary>
public sealed class ReflectionTeamsUiAutomationBackend : ITeamsUiAutomationBackend
{
    public TeamsUiAutomationFailure TryFindExactControl(
        TeamsWindowIdentity identity,
        TeamsMuteAutomationBinding binding,
        out ITeamsUiAutomationControl? control)
    {
        control = null;
        if (!OperatingSystem.IsWindows())
        {
            return TeamsUiAutomationFailure.PlatformUnavailable;
        }

        if (!binding.IsConfigured)
        {
            return TeamsUiAutomationFailure.BindingNotConfigured;
        }

        if (!ReflectionUiAutomationRuntime.TryCreate(out var runtime))
        {
            return TeamsUiAutomationFailure.PlatformUnavailable;
        }

        try
        {
            var elements = runtime.FindExactAutomationId(identity.WindowHandle, binding.AutomationId!);
            if (elements.Count == 0)
            {
                return TeamsUiAutomationFailure.ControlNotFound;
            }

            // Do not choose the first result.  Ambiguous controls fail closed.
            if (elements.Count != 1)
            {
                return TeamsUiAutomationFailure.AmbiguousControls;
            }

            var element = elements[0];
            if (!runtime.IsExactEnabledVisibleButton(element, binding.AutomationId!))
            {
                return TeamsUiAutomationFailure.ControlRejected;
            }

            control = new ReflectionTeamsUiAutomationControl(runtime, element);
            return TeamsUiAutomationFailure.None;
        }
        catch
        {
            return TeamsUiAutomationFailure.StaleElement;
        }
    }
}

internal sealed class ReflectionTeamsUiAutomationControl : ITeamsUiAutomationControl
{
    private readonly ReflectionUiAutomationRuntime runtime;
    private object? element;

    public ReflectionTeamsUiAutomationControl(ReflectionUiAutomationRuntime runtime, object element)
    {
        this.runtime = runtime;
        this.element = element;
    }

    public TeamsUiAutomationFailure ReadToggleState(out bool isOn)
    {
        isOn = false;
        if (element is null)
        {
            return TeamsUiAutomationFailure.StaleElement;
        }

        try
        {
            return runtime.TryReadToggleState(element, out isOn)
                ? TeamsUiAutomationFailure.None
                : TeamsUiAutomationFailure.ControlRejected;
        }
        catch
        {
            return TeamsUiAutomationFailure.StaleElement;
        }
    }

    public TeamsUiAutomationFailure Toggle()
    {
        if (element is null)
        {
            return TeamsUiAutomationFailure.StaleElement;
        }

        try
        {
            return runtime.TryToggle(element)
                ? TeamsUiAutomationFailure.None
                : TeamsUiAutomationFailure.ActionRejected;
        }
        catch
        {
            return TeamsUiAutomationFailure.StaleElement;
        }
    }

    public void Dispose()
    {
        // AutomationElement is a managed UIA wrapper, not an IDisposable.  Drop
        // the reference immediately so this adapter never retains an element,
        // HWND, PID, or user-visible content between operations.
        element = null;
    }
}

/// <summary>Small reflection facade over System.Windows.Automation.</summary>
internal sealed class ReflectionUiAutomationRuntime
{
    private readonly Type automationElementType;
    private readonly Type treeScopeType;
    private readonly Type conditionType;
    private readonly Type propertyConditionType;
    private readonly Type controlTypeType;
    private readonly Type togglePatternType;
    private readonly MethodInfo fromHandle;
    private readonly MethodInfo findAll;
    private readonly MethodInfo getCurrentPattern;
    private readonly object automationIdProperty;
    private readonly object controlTypeButton;
    private readonly object togglePattern;
    private readonly object treeScopeSubtree;

    private ReflectionUiAutomationRuntime(
        Type automationElementType,
        Type treeScopeType,
        Type conditionType,
        Type propertyConditionType,
        Type controlTypeType,
        Type togglePatternType,
        MethodInfo fromHandle,
        MethodInfo findAll,
        MethodInfo getCurrentPattern,
        object automationIdProperty,
        object controlTypeButton,
        object togglePattern,
        object treeScopeSubtree)
    {
        this.automationElementType = automationElementType;
        this.treeScopeType = treeScopeType;
        this.conditionType = conditionType;
        this.propertyConditionType = propertyConditionType;
        this.controlTypeType = controlTypeType;
        this.togglePatternType = togglePatternType;
        this.fromHandle = fromHandle;
        this.findAll = findAll;
        this.getCurrentPattern = getCurrentPattern;
        this.automationIdProperty = automationIdProperty;
        this.controlTypeButton = controlTypeButton;
        this.togglePattern = togglePattern;
        this.treeScopeSubtree = treeScopeSubtree;
    }

    public static bool TryCreate(out ReflectionUiAutomationRuntime runtime)
    {
        runtime = null!;
        try
        {
            var element = Type.GetType("System.Windows.Automation.AutomationElement, UIAutomationClient", throwOnError: false);
            var treeScope = Type.GetType("System.Windows.Automation.TreeScope, UIAutomationClient", throwOnError: false);
            var condition = Type.GetType("System.Windows.Automation.Condition, UIAutomationClient", throwOnError: false);
            var propertyCondition = Type.GetType("System.Windows.Automation.PropertyCondition, UIAutomationClient", throwOnError: false);
            var controlType = Type.GetType("System.Windows.Automation.ControlType, UIAutomationClient", throwOnError: false);
            var toggle = Type.GetType("System.Windows.Automation.TogglePattern, UIAutomationClient", throwOnError: false);
            if (element is null || treeScope is null || condition is null || propertyCondition is null ||
                controlType is null || toggle is null)
            {
                return false;
            }

            var fromHandle = element.GetMethod("FromHandle", BindingFlags.Public | BindingFlags.Static, [typeof(nint)]);
            var findAll = element.GetMethod("FindAll", BindingFlags.Public | BindingFlags.Instance, [treeScope, condition]);
            var getCurrentPattern = element.GetMethod("GetCurrentPattern", BindingFlags.Public | BindingFlags.Instance);
            var automationIdProperty = element.GetProperty("AutomationIdProperty", BindingFlags.Public | BindingFlags.Static)?.GetValue(null);
            var controlTypeButton = controlType.GetProperty("Button", BindingFlags.Public | BindingFlags.Static)?.GetValue(null);
            var togglePattern = toggle.GetProperty("Pattern", BindingFlags.Public | BindingFlags.Static)?.GetValue(null);
            if (fromHandle is null || findAll is null || getCurrentPattern is null || automationIdProperty is null ||
                controlTypeButton is null || togglePattern is null)
            {
                return false;
            }

            runtime = new ReflectionUiAutomationRuntime(
                element,
                treeScope,
                condition,
                propertyCondition,
                controlType,
                toggle,
                fromHandle,
                findAll,
                getCurrentPattern,
                automationIdProperty,
                controlTypeButton,
                togglePattern,
                Enum.Parse(treeScope, "Subtree", ignoreCase: false));
            return true;
        }
        catch
        {
            return false;
        }
    }

    public IReadOnlyList<object> FindExactAutomationId(nint window, string automationId)
    {
        var root = fromHandle.Invoke(null, [window]);
        if (root is null)
        {
            return Array.Empty<object>();
        }

        // This condition is exact and uses only the non-localized AutomationId.
        // It avoids walking/serializing arbitrary on-screen text.
        var condition = Activator.CreateInstance(propertyConditionType, automationIdProperty, automationId);
        if (condition is null)
        {
            return Array.Empty<object>();
        }

        var collection = findAll.Invoke(root, [treeScopeSubtree, condition]);
        if (collection is null)
        {
            return Array.Empty<object>();
        }

        var collectionType = collection.GetType();
        var count = collectionType.GetProperty("Count")?.GetValue(collection) as int? ?? 0;
        if (count <= 0)
        {
            return Array.Empty<object>();
        }

        // There is no safe reason to retain an unbounded list of UIA elements.
        // More than two is already ambiguous; materialize no more than two.
        var item = collectionType.GetProperty("Item");
        if (item is null)
        {
            return Array.Empty<object>();
        }

        var result = new List<object>(Math.Min(count, 2));
        for (var index = 0; index < Math.Min(count, 2); index++)
        {
            var candidate = item.GetValue(collection, [index]);
            if (candidate is not null)
            {
                result.Add(candidate);
            }
        }
        return count > 2 ? [new object(), new object()] : result;
    }

    public bool IsExactEnabledVisibleButton(object element, string automationId)
    {
        var current = element.GetType().GetProperty("Current")?.GetValue(element);
        if (current is null)
        {
            return false;
        }

        var currentType = current.GetType();
        var id = currentType.GetProperty("AutomationId")?.GetValue(current) as string;
        var enabled = currentType.GetProperty("IsEnabled")?.GetValue(current) as bool?;
        var offscreen = currentType.GetProperty("IsOffscreen")?.GetValue(current) as bool?;
        var type = currentType.GetProperty("ControlType")?.GetValue(current);
        return string.Equals(id, automationId, StringComparison.Ordinal) &&
               enabled == true && offscreen == false &&
               Equals(type, controlTypeButton);
    }

    public bool TryReadToggleState(object element, out bool isOn)
    {
        isOn = false;
        var pattern = getCurrentPattern.Invoke(element, [togglePattern]);
        if (pattern is null)
        {
            return false;
        }

        var current = pattern.GetType().GetProperty("Current")?.GetValue(pattern);
        var state = current?.GetType().GetProperty("ToggleState")?.GetValue(current)?.ToString();
        if (string.Equals(state, "On", StringComparison.Ordinal))
        {
            isOn = true;
            return true;
        }

        return string.Equals(state, "Off", StringComparison.Ordinal);
    }

    public bool TryToggle(object element)
    {
        var pattern = getCurrentPattern.Invoke(element, [togglePattern]);
        var toggle = pattern?.GetType().GetMethod("Toggle", BindingFlags.Public | BindingFlags.Instance);
        if (toggle is null)
        {
            return false;
        }

        toggle.Invoke(pattern, null);
        return true;
    }
}
