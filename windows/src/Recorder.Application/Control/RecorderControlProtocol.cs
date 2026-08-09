using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TeamsRecorder.Windows.Application.Control;

/// <summary>
/// Versioned, one-request/one-response local-control contract shared by the
/// Windows recorder application and <c>recorderctl</c>.  It deliberately
/// contains no filesystem locations, process/window identities, or provider
/// credentials: a local control endpoint should not become a diagnostics or
/// data-export endpoint.
/// </summary>
public static class RecorderControlProtocol
{
    /// <summary>Matches the current macOS recorder-control protocol version.</summary>
    public const int CurrentVersion = 1;

    /// <summary>
    /// A complete UTF-8 newline-delimited request or response, including its
    /// newline terminator, must fit within this limit.
    /// </summary>
    public const int MaximumFrameBytes = 65_536;

    public const int MaximumRequestIdCharacters = 128;
    public const int MaximumArgumentCharacters = 32;
    public const int MaximumAppVersionCharacters = 80;

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = null,
        DictionaryKeyPolicy = null,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        NumberHandling = JsonNumberHandling.Strict,
        WriteIndented = false,
    };

    static RecorderControlProtocol()
    {
        SerializerOptions.Converters.Add(new RecorderControlCommandConverter());
        SerializerOptions.Converters.Add(new RecorderControlRecordingStateConverter());
        SerializerOptions.Converters.Add(new RecorderControlLifecycleOperationConverter());
    }

    public static byte[] SerializeRequest(RecorderControlRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        request.Validate();
        return Serialize(request);
    }

    public static byte[] SerializeResponse(RecorderControlResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        response.Validate();
        return Serialize(response);
    }

    public static RecorderControlRequest DeserializeRequest(ReadOnlySpan<byte> utf8Json)
    {
        try
        {
            var request = JsonSerializer.Deserialize<RecorderControlRequest>(utf8Json, SerializerOptions)
                ?? throw new RecorderControlProtocolException(RecorderControlProtocolError.MalformedFrame);
            request.Validate();
            return request;
        }
        catch (JsonException)
        {
            throw new RecorderControlProtocolException(RecorderControlProtocolError.MalformedFrame);
        }
        catch (NotSupportedException)
        {
            throw new RecorderControlProtocolException(RecorderControlProtocolError.MalformedFrame);
        }
    }

    public static RecorderControlResponse DeserializeResponse(ReadOnlySpan<byte> utf8Json)
    {
        try
        {
            var response = JsonSerializer.Deserialize<RecorderControlResponse>(utf8Json, SerializerOptions)
                ?? throw new RecorderControlProtocolException(RecorderControlProtocolError.MalformedFrame);
            response.Validate();
            return response;
        }
        catch (JsonException)
        {
            throw new RecorderControlProtocolException(RecorderControlProtocolError.MalformedFrame);
        }
        catch (NotSupportedException)
        {
            throw new RecorderControlProtocolException(RecorderControlProtocolError.MalformedFrame);
        }
    }

    public static string SerializeStatusJson(RecorderControlStatus status)
    {
        ArgumentNullException.ThrowIfNull(status);
        status.Validate();
        return Encoding.UTF8.GetString(JsonSerializer.SerializeToUtf8Bytes(status, SerializerOptions));
    }

    internal static bool IsSafeRequestId(string? value)
    {
        if (string.IsNullOrEmpty(value) || value.Length > MaximumRequestIdCharacters)
        {
            return false;
        }

        foreach (var character in value)
        {
            if (!(char.IsAsciiLetterOrDigit(character) || character is '-' or '_'))
            {
                return false;
            }
        }

        return true;
    }

    internal static bool IsSafeArgument(string? value) =>
        value is null || (value.Length <= MaximumArgumentCharacters && value.All(character =>
            char.IsAsciiLetterOrDigit(character) || character is '-' or '_'));

    internal static bool IsSafeAppVersion(string? value)
    {
        if (string.IsNullOrEmpty(value) || value.Length > MaximumAppVersionCharacters)
        {
            return false;
        }

        foreach (var character in value)
        {
            if (!(char.IsAsciiLetterOrDigit(character) || character is '.' or '-' or '+'))
            {
                return false;
            }
        }

        return true;
    }

    private static byte[] Serialize<T>(T value)
    {
        var utf8Json = JsonSerializer.SerializeToUtf8Bytes(value, SerializerOptions);
        if (utf8Json.Length >= MaximumFrameBytes)
        {
            throw new RecorderControlProtocolException(RecorderControlProtocolError.OversizedFrame);
        }

        return utf8Json;
    }
}

/// <summary>Commands intentionally mirror the macOS recorderctl contract.</summary>
public enum RecorderControlCommand
{
    Status,
    Start,
    Stop,
    SetAuto,
    SetMic,
}

public enum RecorderControlRecordingState
{
    Idle,
    Starting,
    Recording,
    Stopping,
    Faulted,
}

public enum RecorderControlLifecycleOperation
{
    None,
    Refresh,
    Permission,
    Start,
    Stop,
    Finalize,
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
[method: JsonConstructor]
public sealed record RecorderControlRequest(
    [property: JsonPropertyName("protocolVersion")] int ProtocolVersion,
    [property: JsonPropertyName("requestID")] string RequestId,
    [property: JsonPropertyName("command")] RecorderControlCommand Command,
    [property: JsonPropertyName("argument")] string? Argument = null)
{
    public RecorderControlRequest(string requestId, RecorderControlCommand command, string? argument = null)
        : this(RecorderControlProtocol.CurrentVersion, requestId, command, argument)
    {
    }

    public void Validate()
    {
        if (!RecorderControlProtocol.IsSafeRequestId(RequestId) ||
            !RecorderControlProtocol.IsSafeArgument(Argument))
        {
            throw new RecorderControlProtocolException(RecorderControlProtocolError.InvalidRequest);
        }
    }
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record RecorderControlErrorPayload(
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("message")] string Message)
{
    public void Validate()
    {
        if (!RecorderControlErrorCatalog.IsKnown(Code) ||
            !string.Equals(Message, RecorderControlErrorCatalog.MessageFor(Code), StringComparison.Ordinal))
        {
            throw new RecorderControlProtocolException(RecorderControlProtocolError.InvalidResponse);
        }
    }
}

/// <summary>
/// A privacy-safe status projection.  The omission of arbitrary message text,
/// output folders, PIDs, HWNDs, device IDs, and provider settings is deliberate.
/// </summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record RecorderControlStatus(
    [property: JsonPropertyName("appRunning")] bool AppRunning,
    [property: JsonPropertyName("appVersion")] string AppVersion,
    [property: JsonPropertyName("recordingState")] RecorderControlRecordingState RecordingState,
    [property: JsonPropertyName("lifecycleOperation")] RecorderControlLifecycleOperation LifecycleOperation,
    [property: JsonPropertyName("elapsedSeconds")] long? ElapsedSeconds,
    [property: JsonPropertyName("microphoneMuted")] bool MicrophoneMuted,
    [property: JsonPropertyName("autoModeEnabled")] bool AutoModeEnabled)
{
    public void Validate()
    {
        if (!RecorderControlProtocol.IsSafeAppVersion(AppVersion) ||
            (ElapsedSeconds is < 0 or > 31_536_000))
        {
            throw new RecorderControlProtocolException(RecorderControlProtocolError.InvalidResponse);
        }
    }
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record RecorderControlResponse(
    [property: JsonPropertyName("protocolVersion")] int ProtocolVersion,
    [property: JsonPropertyName("requestID")] string RequestId,
    [property: JsonPropertyName("ok")] bool Ok,
    [property: JsonPropertyName("status")] RecorderControlStatus? Status,
    [property: JsonPropertyName("error")] RecorderControlErrorPayload? Error)
{
    public static RecorderControlResponse Success(string requestId, RecorderControlStatus status) =>
        new(RecorderControlProtocol.CurrentVersion, requestId, true, status, null);

    public static RecorderControlResponse Failure(string requestId, RecorderControlErrorCode error) =>
        new(
            RecorderControlProtocol.CurrentVersion,
            RecorderControlErrorCatalog.SafeRequestIdOrEmpty(requestId),
            false,
            null,
            new RecorderControlErrorPayload(
                RecorderControlErrorCatalog.CodeFor(error),
                RecorderControlErrorCatalog.MessageFor(RecorderControlErrorCatalog.CodeFor(error))));

    public void Validate()
    {
        if (ProtocolVersion != RecorderControlProtocol.CurrentVersion ||
            !RecorderControlProtocol.IsSafeRequestId(RequestId))
        {
            throw new RecorderControlProtocolException(RecorderControlProtocolError.InvalidResponse);
        }

        if (Ok)
        {
            if (Status is null || Error is not null)
            {
                throw new RecorderControlProtocolException(RecorderControlProtocolError.InvalidResponse);
            }

            Status.Validate();
            return;
        }

        if (Status is not null || Error is null)
        {
            throw new RecorderControlProtocolException(RecorderControlProtocolError.InvalidResponse);
        }

        Error.Validate();
    }
}

public enum RecorderControlProtocolError
{
    MalformedFrame,
    OversizedFrame,
    InvalidRequest,
    InvalidResponse,
    TimedOut,
    UnauthorizedPeer,
    ServiceStopped,
}

public sealed class RecorderControlProtocolException : Exception
{
    public RecorderControlProtocolException(RecorderControlProtocolError error)
        : base("Recorder control protocol rejected the frame.")
    {
        Error = error;
    }

    public RecorderControlProtocolError Error { get; }
}

public enum RecorderControlErrorCode
{
    UnsupportedProtocol,
    InvalidArgument,
    Busy,
    NotReady,
    ServerStopped,
    UnsupportedCommand,
    MalformedRequest,
    TimedOut,
}

internal static class RecorderControlErrorCatalog
{
    public static string SafeRequestIdOrEmpty(string? requestId) =>
        RecorderControlProtocol.IsSafeRequestId(requestId) ? requestId! : "invalid";

    public static string CodeFor(RecorderControlErrorCode error) => error switch
    {
        RecorderControlErrorCode.UnsupportedProtocol => "unsupported_protocol",
        RecorderControlErrorCode.InvalidArgument => "invalid_argument",
        RecorderControlErrorCode.Busy => "busy",
        RecorderControlErrorCode.NotReady => "not_ready",
        RecorderControlErrorCode.ServerStopped => "server_stopped",
        RecorderControlErrorCode.UnsupportedCommand => "unsupported_command",
        RecorderControlErrorCode.MalformedRequest => "malformed_request",
        RecorderControlErrorCode.TimedOut => "timed_out",
        _ => throw new ArgumentOutOfRangeException(nameof(error)),
    };

    public static bool IsKnown(string code) =>
        code is "unsupported_protocol" or "invalid_argument" or "busy" or "not_ready" or
            "server_stopped" or "unsupported_command" or "malformed_request" or "timed_out";

    public static string MessageFor(string code) => code switch
    {
        "unsupported_protocol" => "Unsupported protocol version.",
        "invalid_argument" => "Invalid command argument.",
        "busy" => "Another recorder control operation is in progress.",
        "not_ready" => "Recorder is not ready for that operation.",
        "server_stopped" => "Recorder control service is stopped.",
        "unsupported_command" => "This recorder control command is unavailable.",
        "malformed_request" => "Malformed recorder control request.",
        "timed_out" => "Recorder control request timed out.",
        _ => throw new ArgumentOutOfRangeException(nameof(code)),
    };
}

internal sealed class RecorderControlCommandConverter : JsonConverter<RecorderControlCommand>
{
    public override RecorderControlCommand Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException();
        }

        return reader.GetString() switch
        {
            "status" => RecorderControlCommand.Status,
            "start" => RecorderControlCommand.Start,
            "stop" => RecorderControlCommand.Stop,
            "set-auto" => RecorderControlCommand.SetAuto,
            "set-mic" => RecorderControlCommand.SetMic,
            _ => throw new JsonException(),
        };
    }

    public override void Write(Utf8JsonWriter writer, RecorderControlCommand value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch
        {
            RecorderControlCommand.Status => "status",
            RecorderControlCommand.Start => "start",
            RecorderControlCommand.Stop => "stop",
            RecorderControlCommand.SetAuto => "set-auto",
            RecorderControlCommand.SetMic => "set-mic",
            _ => throw new JsonException(),
        });
}

internal sealed class RecorderControlRecordingStateConverter : JsonConverter<RecorderControlRecordingState>
{
    public override RecorderControlRecordingState Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String ? reader.GetString() switch
        {
            "idle" => RecorderControlRecordingState.Idle,
            "starting" => RecorderControlRecordingState.Starting,
            "recording" => RecorderControlRecordingState.Recording,
            "stopping" => RecorderControlRecordingState.Stopping,
            "faulted" => RecorderControlRecordingState.Faulted,
            _ => throw new JsonException(),
        } : throw new JsonException();

    public override void Write(Utf8JsonWriter writer, RecorderControlRecordingState value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch
        {
            RecorderControlRecordingState.Idle => "idle",
            RecorderControlRecordingState.Starting => "starting",
            RecorderControlRecordingState.Recording => "recording",
            RecorderControlRecordingState.Stopping => "stopping",
            RecorderControlRecordingState.Faulted => "faulted",
            _ => throw new JsonException(),
        });
}

internal sealed class RecorderControlLifecycleOperationConverter : JsonConverter<RecorderControlLifecycleOperation>
{
    public override RecorderControlLifecycleOperation Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String ? reader.GetString() switch
        {
            "none" => RecorderControlLifecycleOperation.None,
            "refresh" => RecorderControlLifecycleOperation.Refresh,
            "permission" => RecorderControlLifecycleOperation.Permission,
            "start" => RecorderControlLifecycleOperation.Start,
            "stop" => RecorderControlLifecycleOperation.Stop,
            "finalize" => RecorderControlLifecycleOperation.Finalize,
            _ => throw new JsonException(),
        } : throw new JsonException();

    public override void Write(Utf8JsonWriter writer, RecorderControlLifecycleOperation value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch
        {
            RecorderControlLifecycleOperation.None => "none",
            RecorderControlLifecycleOperation.Refresh => "refresh",
            RecorderControlLifecycleOperation.Permission => "permission",
            RecorderControlLifecycleOperation.Start => "start",
            RecorderControlLifecycleOperation.Stop => "stop",
            RecorderControlLifecycleOperation.Finalize => "finalize",
            _ => throw new JsonException(),
        });
}
