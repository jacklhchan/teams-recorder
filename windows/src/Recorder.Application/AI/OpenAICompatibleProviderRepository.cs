using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace TeamsRecorder.Windows.Application.AI;

public interface IOpenAICompatibleProviderProfileStore
{
    Task<OpenAICompatibleProviderProfile?> LoadAsync(CancellationToken cancellationToken = default);
    Task SaveAsync(OpenAICompatibleProviderProfile profile, CancellationToken cancellationToken = default);
}

public interface IOpenAICompatibleApiKeyStore
{
    Task<string?> ReadAsync(CancellationToken cancellationToken = default);
    Task WriteAsync(string apiKey, CancellationToken cancellationToken = default);
    Task ClearAsync(CancellationToken cancellationToken = default);
}

public sealed record OpenAICompatibleProviderSnapshot(OpenAICompatibleProviderProfile Profile, string? ApiKey);

public sealed class OpenAICompatibleProviderRepository(
    IOpenAICompatibleProviderProfileStore profiles,
    IOpenAICompatibleApiKeyStore apiKeys)
{
    public async Task<OpenAICompatibleProviderProfile?> LoadProfileAsync(CancellationToken cancellationToken = default) =>
        Validate(await profiles.LoadAsync(cancellationToken).ConfigureAwait(false));

    public async Task SaveAsync(OpenAICompatibleProviderProfile profile, string? replacementApiKey, CancellationToken cancellationToken = default)
    {
        var validated = Validate(profile)!;
        if (!string.IsNullOrWhiteSpace(replacementApiKey)) await apiKeys.WriteAsync(replacementApiKey, cancellationToken).ConfigureAwait(false);
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
        new(OpenAICompatibleProviderProfile.ValidateStored(profile), await apiKeys.ReadAsync(cancellationToken).ConfigureAwait(false));

    public async Task<bool> HasApiKeyAsync(CancellationToken cancellationToken = default) =>
        !string.IsNullOrWhiteSpace(await apiKeys.ReadAsync(cancellationToken).ConfigureAwait(false));

    public Task ClearApiKeyAsync(CancellationToken cancellationToken = default) => apiKeys.ClearAsync(cancellationToken);
    private static OpenAICompatibleProviderProfile? Validate(OpenAICompatibleProviderProfile? profile) =>
        profile is null ? null : OpenAICompatibleProviderProfile.ValidateStored(profile);
}

public sealed class JsonOpenAICompatibleProviderProfileStore(string? path = null) : IOpenAICompatibleProviderProfileStore
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = false };
    private readonly string path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Teams Recorder", "openai-provider-profile.json");

    public async Task<OpenAICompatibleProviderProfile?> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(path)) return null;
        try
        {
            await using var stream = File.OpenRead(path);
            var profile = await JsonSerializer.DeserializeAsync<OpenAICompatibleProviderProfile>(stream, Options, cancellationToken).ConfigureAwait(false);
            return profile is null ? throw new ProviderRepositoryException("The saved AI provider profile is invalid.") : OpenAICompatibleProviderProfile.ValidateStored(profile);
        }
        catch (ProviderProfileException) { throw; }
        catch (JsonException) { throw new ProviderRepositoryException("The saved AI provider profile is invalid."); }
        catch (IOException) { throw new ProviderRepositoryException("The saved AI provider profile could not be read."); }
        catch (UnauthorizedAccessException) { throw new ProviderRepositoryException("The saved AI provider profile could not be read."); }
    }

    public async Task SaveAsync(OpenAICompatibleProviderProfile profile, CancellationToken cancellationToken = default)
    {
        var validated = OpenAICompatibleProviderProfile.ValidateStored(profile);
        var directory = Path.GetDirectoryName(path) ?? throw new ProviderRepositoryException("The AI provider profile could not be saved.");
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            Directory.CreateDirectory(directory);
            await using (var stream = File.Create(temporary)) await JsonSerializer.SerializeAsync(stream, validated, Options, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, path, overwrite: true);
        }
        catch (ProviderProfileException) { throw; }
        catch (IOException) { throw new ProviderRepositoryException("The AI provider profile could not be saved."); }
        catch (UnauthorizedAccessException) { throw new ProviderRepositoryException("The AI provider profile could not be saved."); }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch { } }
    }
}

/// <summary>DPAPI current-user credential storage. The JSON profile never contains the key.</summary>
public sealed class WindowsDpapiOpenAICompatibleApiKeyStore(string? path = null) : IOpenAICompatibleApiKeyStore
{
    private const string Entropy = "TeamsRecorder.Windows.OpenAICompatibleProvider.v1";
    private readonly string path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Teams Recorder", "openai-provider-api-key.bin");
    public async Task<string?> ReadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(path)) return null;
        var encrypted = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
        if (encrypted.Length == 0) return null;
        return Encoding.UTF8.GetString(Dpapi.Transform(encrypted, Encoding.UTF8.GetBytes(Entropy), protect: false));
    }
    public async Task WriteAsync(string apiKey, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(apiKey);
        var directory = Path.GetDirectoryName(path) ?? throw new ProviderRepositoryException("The AI provider credential could not be saved.");
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try { Directory.CreateDirectory(directory); await File.WriteAllBytesAsync(temporary, Dpapi.Transform(Encoding.UTF8.GetBytes(apiKey), Encoding.UTF8.GetBytes(Entropy), true), cancellationToken).ConfigureAwait(false); File.Move(temporary, path, true); }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch { } }
    }
    public Task ClearAsync(CancellationToken cancellationToken = default) { cancellationToken.ThrowIfCancellationRequested(); if (File.Exists(path)) File.Delete(path); return Task.CompletedTask; }

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
