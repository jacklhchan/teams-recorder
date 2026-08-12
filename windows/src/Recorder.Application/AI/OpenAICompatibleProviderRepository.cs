using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace TeamsRecorder.Windows.Application.AI;

public interface IOpenAICompatibleProviderProfileStore
{
    Task<OpenAICompatibleProviderProfile?> LoadAsync(CancellationToken cancellationToken = default);
    async Task<OpenAICompatibleProviderProfile?> LoadAsync(
        AIProviderKind kind,
        CancellationToken cancellationToken = default)
    {
        var profile = await LoadAsync(cancellationToken).ConfigureAwait(false);
        return profile?.ProviderKind == kind ? profile : null;
    }
    Task SaveAsync(OpenAICompatibleProviderProfile profile, CancellationToken cancellationToken = default);
}

public interface IOpenAICompatibleApiKeyStore
{
    Task<string?> ReadAsync(CancellationToken cancellationToken = default);
    Task<string?> ReadAsync(AIProviderKind kind, CancellationToken cancellationToken = default) =>
        ReadAsync(cancellationToken);
    Task WriteAsync(string apiKey, CancellationToken cancellationToken = default);
    Task WriteAsync(AIProviderKind kind, string apiKey, CancellationToken cancellationToken = default) =>
        WriteAsync(apiKey, cancellationToken);
    Task ClearAsync(CancellationToken cancellationToken = default);
    Task ClearAsync(AIProviderKind kind, CancellationToken cancellationToken = default) =>
        ClearAsync(cancellationToken);
}

public sealed record OpenAICompatibleProviderSnapshot(OpenAICompatibleProviderProfile Profile, string? ApiKey);

public sealed class OpenAICompatibleProviderRepository(
    IOpenAICompatibleProviderProfileStore profiles,
    IOpenAICompatibleApiKeyStore apiKeys)
{
    public async Task<OpenAICompatibleProviderProfile?> LoadProfileAsync(CancellationToken cancellationToken = default) =>
        Validate(await profiles.LoadAsync(cancellationToken).ConfigureAwait(false));

    public async Task<OpenAICompatibleProviderProfile?> LoadProfileAsync(
        AIProviderKind kind,
        CancellationToken cancellationToken = default) =>
        Validate(await profiles.LoadAsync(kind, cancellationToken).ConfigureAwait(false));

    public async Task SaveAsync(OpenAICompatibleProviderProfile profile, string? replacementApiKey, CancellationToken cancellationToken = default)
    {
        var validated = Validate(profile)!;
        if (!string.IsNullOrWhiteSpace(replacementApiKey))
            await apiKeys.WriteAsync(validated.ProviderKind, replacementApiKey, cancellationToken).ConfigureAwait(false);
        await profiles.SaveAsync(validated, cancellationToken).ConfigureAwait(false);
    }

    public async Task<OpenAICompatibleProviderSnapshot> SnapshotAsync(CancellationToken cancellationToken = default)
    {
        var profile = await LoadProfileAsync(cancellationToken).ConfigureAwait(false)
            ?? throw new ProviderRepositoryException("Configure an AI provider before starting transcription.");
        return await SnapshotAsync(profile, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Uses a validated, unsaved draft profile with the current secure key for a connection test.</summary>
    public async Task<OpenAICompatibleProviderSnapshot> SnapshotAsync(
        OpenAICompatibleProviderProfile profile,
        CancellationToken cancellationToken = default) =>
        new(OpenAICompatibleProviderProfile.ValidateStored(profile),
            await apiKeys.ReadAsync(profile.ProviderKind, cancellationToken).ConfigureAwait(false));

    public async Task<bool> HasApiKeyAsync(CancellationToken cancellationToken = default)
    {
        var profile = await LoadProfileAsync(cancellationToken).ConfigureAwait(false);
        return profile is not null && await HasApiKeyAsync(profile.ProviderKind, cancellationToken).ConfigureAwait(false);
    }

    public async Task<bool> HasApiKeyAsync(
        AIProviderKind kind,
        CancellationToken cancellationToken = default) =>
        !string.IsNullOrWhiteSpace(await apiKeys.ReadAsync(kind, cancellationToken).ConfigureAwait(false));

    public async Task ClearApiKeyAsync(CancellationToken cancellationToken = default)
    {
        var profile = await LoadProfileAsync(cancellationToken).ConfigureAwait(false);
        if (profile is not null) await ClearApiKeyAsync(profile.ProviderKind, cancellationToken).ConfigureAwait(false);
    }

    public Task ClearApiKeyAsync(AIProviderKind kind, CancellationToken cancellationToken = default) =>
        apiKeys.ClearAsync(kind, cancellationToken);
    private static OpenAICompatibleProviderProfile? Validate(OpenAICompatibleProviderProfile? profile) =>
        profile is null ? null : OpenAICompatibleProviderProfile.ValidateStored(profile);
}

public sealed class JsonOpenAICompatibleProviderProfileStore(string? path = null) : IOpenAICompatibleProviderProfileStore
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = false };
    private readonly string path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Teams Recorder", "openai-provider-profile.json");

    public async Task<OpenAICompatibleProviderProfile?> LoadAsync(CancellationToken cancellationToken = default)
    {
        var activeKind = await LoadActiveKindAsync(cancellationToken).ConfigureAwait(false);
        if (activeKind is { } selected)
        {
            var active = await LoadAsync(selected, cancellationToken).ConfigureAwait(false);
            if (active is not null) return active;
        }

        return await LoadAsync(AIProviderKind.OpenAICompatible, cancellationToken).ConfigureAwait(false)
            ?? await LoadAsync(AIProviderKind.HktGenAI, cancellationToken).ConfigureAwait(false);
    }

    public async Task<OpenAICompatibleProviderProfile?> LoadAsync(
        AIProviderKind kind,
        CancellationToken cancellationToken = default)
    {
        var providerPath = ProviderPath(kind);
        var legacyHktLocation = false;
        if (!File.Exists(providerPath) && kind == AIProviderKind.HktGenAI)
        {
            // Schema v3 initially stored whichever provider was active in the
            // generic filename. Read that HKT profile once for migration.
            providerPath = path;
            legacyHktLocation = true;
        }
        if (!File.Exists(providerPath)) return null;
        try
        {
            EnsureSafeRegularFile(providerPath);
            await using var stream = File.OpenRead(providerPath);
            var profile = await JsonSerializer.DeserializeAsync<OpenAICompatibleProviderProfile>(stream, Options, cancellationToken).ConfigureAwait(false);
            if (profile is null) throw new ProviderRepositoryException("The saved AI provider profile is invalid.");
            var validated = OpenAICompatibleProviderProfile.ValidateStored(profile);
            if (validated.ProviderKind != kind) return null;
            if (legacyHktLocation) TryCopyLegacyHktProfile(providerPath);
            return validated;
        }
        catch (ProviderProfileException) { throw; }
        catch (JsonException) { throw new ProviderRepositoryException("The saved AI provider profile is invalid."); }
        catch (IOException) { throw new ProviderRepositoryException("The saved AI provider profile could not be read."); }
        catch (UnauthorizedAccessException) { throw new ProviderRepositoryException("The saved AI provider profile could not be read."); }
    }

    public async Task SaveAsync(OpenAICompatibleProviderProfile profile, CancellationToken cancellationToken = default)
    {
        var validated = OpenAICompatibleProviderProfile.ValidateStored(profile);
        var providerPath = ProviderPath(validated.ProviderKind);
        var directory = Path.GetDirectoryName(providerPath) ?? throw new ProviderRepositoryException("The AI provider profile could not be saved.");
        var temporary = providerPath + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            Directory.CreateDirectory(directory);
            await using (var stream = File.Create(temporary)) await JsonSerializer.SerializeAsync(stream, validated, Options, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, providerPath, overwrite: true);
            await SaveActiveKindAsync(validated.ProviderKind, cancellationToken).ConfigureAwait(false);
        }
        catch (ProviderProfileException) { throw; }
        catch (IOException) { throw new ProviderRepositoryException("The AI provider profile could not be saved."); }
        catch (UnauthorizedAccessException) { throw new ProviderRepositoryException("The AI provider profile could not be saved."); }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch { } }
    }

    private string ProviderPath(AIProviderKind kind) => kind == AIProviderKind.OpenAICompatible
        ? path
        : AddQualifier(path, "hkt");

    private string ActiveKindPath => AddQualifier(path, "active");

    private void TryCopyLegacyHktProfile(string source)
    {
        try
        {
            var destination = ProviderPath(AIProviderKind.HktGenAI);
            if (!File.Exists(destination)) File.Copy(source, destination, overwrite: false);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private async Task<AIProviderKind?> LoadActiveKindAsync(CancellationToken cancellationToken)
    {
        try
        {
            if (!File.Exists(ActiveKindPath)) return null;
            EnsureSafeRegularFile(ActiveKindPath);
            var value = (await File.ReadAllTextAsync(ActiveKindPath, cancellationToken).ConfigureAwait(false)).Trim();
            return Enum.TryParse<AIProviderKind>(value, ignoreCase: false, out var kind) ? kind : null;
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    private async Task SaveActiveKindAsync(AIProviderKind kind, CancellationToken cancellationToken)
    {
        var activePath = ActiveKindPath;
        var temporary = activePath + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await File.WriteAllTextAsync(temporary, kind.ToString(), cancellationToken).ConfigureAwait(false);
            File.Move(temporary, activePath, overwrite: true);
        }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch { } }
    }

    private static string AddQualifier(string value, string qualifier)
    {
        var extension = Path.GetExtension(value);
        return extension.Length == 0
            ? value + "." + qualifier
            : value[..^extension.Length] + "." + qualifier + extension;
    }

    private static void EnsureSafeRegularFile(string value)
    {
        var attributes = File.GetAttributes(value);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new ProviderRepositoryException("The saved AI provider profile is invalid.");
    }
}

/// <summary>DPAPI current-user credential storage. The JSON profile never contains the key.</summary>
public sealed class WindowsDpapiOpenAICompatibleApiKeyStore(string? path = null) : IOpenAICompatibleApiKeyStore
{
    private const string Entropy = "TeamsRecorder.Windows.OpenAICompatibleProvider.v1";
    private readonly string path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Teams Recorder", "openai-provider-api-key.bin");
    public Task<string?> ReadAsync(CancellationToken cancellationToken = default) =>
        ReadAsync(AIProviderKind.OpenAICompatible, cancellationToken);

    public async Task<string?> ReadAsync(AIProviderKind kind, CancellationToken cancellationToken = default)
    {
        var keyPath = ProviderPath(kind);
        if (!File.Exists(keyPath)) return null;
        var attributes = File.GetAttributes(keyPath);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new ProviderRepositoryException("The AI provider credential could not be accessed.");
        var encrypted = await File.ReadAllBytesAsync(keyPath, cancellationToken).ConfigureAwait(false);
        if (encrypted.Length == 0) return null;
        return Encoding.UTF8.GetString(Dpapi.Transform(encrypted, EntropyBytes(kind), protect: false));
    }

    public Task WriteAsync(string apiKey, CancellationToken cancellationToken = default) =>
        WriteAsync(AIProviderKind.OpenAICompatible, apiKey, cancellationToken);

    public async Task WriteAsync(AIProviderKind kind, string apiKey, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(apiKey);
        var keyPath = ProviderPath(kind);
        var directory = Path.GetDirectoryName(keyPath) ?? throw new ProviderRepositoryException("The AI provider credential could not be saved.");
        var temporary = keyPath + ".tmp-" + Guid.NewGuid().ToString("N");
        try { Directory.CreateDirectory(directory); await File.WriteAllBytesAsync(temporary, Dpapi.Transform(Encoding.UTF8.GetBytes(apiKey), EntropyBytes(kind), true), cancellationToken).ConfigureAwait(false); File.Move(temporary, keyPath, true); }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch { } }
    }

    public Task ClearAsync(CancellationToken cancellationToken = default) =>
        ClearAsync(AIProviderKind.OpenAICompatible, cancellationToken);

    public Task ClearAsync(AIProviderKind kind, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var keyPath = ProviderPath(kind);
        if (File.Exists(keyPath)) File.Delete(keyPath);
        return Task.CompletedTask;
    }

    private string ProviderPath(AIProviderKind kind) => kind == AIProviderKind.OpenAICompatible
        ? path
        : AddQualifier(path, "hkt");

    private static string AddQualifier(string value, string qualifier)
    {
        var extension = Path.GetExtension(value);
        return extension.Length == 0
            ? value + "." + qualifier
            : value[..^extension.Length] + "." + qualifier + extension;
    }

    private static byte[] EntropyBytes(AIProviderKind kind) => Encoding.UTF8.GetBytes(
        kind == AIProviderKind.OpenAICompatible ? Entropy : Entropy + ".HktGenAI");

    private static class Dpapi
    {
        [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Length; public IntPtr Data; }
        [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool CryptProtectData(ref Blob input, string? description, ref Blob entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
        [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, ref Blob entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
        public static byte[] Transform(byte[] input, byte[] entropy, bool protect)
        {
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Per-user credential storage requires Windows.");
            var inputHandle = GCHandle.Alloc(input, GCHandleType.Pinned); var entropyHandle = GCHandle.Alloc(entropy, GCHandleType.Pinned);
            try
            {
                var source = new Blob { Length = input.Length, Data = inputHandle.AddrOfPinnedObject() }; var optionalEntropy = new Blob { Length = entropy.Length, Data = entropyHandle.AddrOfPinnedObject() };
                var success = protect ? CryptProtectData(ref source, null, ref optionalEntropy, IntPtr.Zero, IntPtr.Zero, 1, out var output) : CryptUnprotectData(ref source, IntPtr.Zero, ref optionalEntropy, IntPtr.Zero, IntPtr.Zero, 1, out output);
                if (!success) throw new ProviderRepositoryException("The AI provider credential could not be accessed.");
                try { var result = new byte[output.Length]; Marshal.Copy(output.Data, result, 0, result.Length); return result; } finally { if (output.Data != IntPtr.Zero) LocalFree(output.Data); }
            }
            finally { entropyHandle.Free(); inputHandle.Free(); }
        }
    }
}

public sealed class ProviderRepositoryException(string message) : InvalidOperationException(message);
