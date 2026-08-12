namespace Recorder.Core;

/// <summary>
/// Bounded, presentation-safe Windows executable basenames used for capture
/// provenance. This deliberately accepts ordinary spaces and Unicode names,
/// but never accepts a path, command line, control character, or Windows
/// reserved filename punctuation.
/// </summary>
public static class WindowsExecutableBasename
{
    public const int MaximumLength = 128;

    public static string ToExecutableBasename(string value)
    {
        if (!TryCreateExecutableBasename(value, out var result))
        {
            throw new ArgumentException("A safe Windows executable basename is required.", nameof(value));
        }

        return result;
    }

    public static bool TryCreateExecutableBasename(string? value, out string result)
    {
        result = string.Empty;
        if (!TryNormalize(value, requireExeExtension: false, out var normalized))
        {
            return false;
        }

        var candidate = normalized.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
            ? normalized
            : normalized + ".exe";
        return TryNormalize(candidate, requireExeExtension: true, out result);
    }

    public static bool TryNormalize(string? value, bool requireExeExtension, out string result)
    {
        result = string.Empty;
        if (string.IsNullOrEmpty(value) || value.Length > MaximumLength ||
            value[^1] is ' ' or '.' || value.Any(char.IsControl) ||
            value.IndexOfAny(['<', '>', ':', '"', '/', '\\', '|', '?', '*', '\0']) >= 0)
        {
            return false;
        }

        var hasExeExtension = value.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);
        if (requireExeExtension && !hasExeExtension)
        {
            return false;
        }

        if (hasExeExtension && value.Length == 4)
        {
            return false;
        }

        result = value;
        return true;
    }
}
