using System.Text.Json;
using Json.Schema;

if (args.Length < 2)
{
    Console.Error.WriteLine("Usage: ContractSchemaValidator <schema-path> <instance-path> [...instance-path]");
    return 64;
}

var schemaPath = Path.GetFullPath(args[0]);
if (!File.Exists(schemaPath))
{
    Console.Error.WriteLine($"Schema file does not exist: {schemaPath}");
    return 66;
}

JsonSchema schema;
try
{
    schema = JsonSchema.FromText(await File.ReadAllTextAsync(schemaPath));
}
catch (Exception exception)
{
    Console.Error.WriteLine($"Unable to parse JSON Schema '{schemaPath}': {exception.Message}");
    return 65;
}

var options = new EvaluationOptions
{
    OutputFormat = OutputFormat.List,
};
var exitCode = 0;

foreach (var instancePathArgument in args.Skip(1))
{
    var instancePath = Path.GetFullPath(instancePathArgument);
    try
    {
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(instancePath));
        var result = schema.Evaluate(document.RootElement, options);
        if (result.IsValid)
        {
            Console.WriteLine($"Schema-valid: {instancePath}");
            continue;
        }

        Console.Error.WriteLine($"Schema-invalid: {instancePath}");
        Console.Error.WriteLine("The instance does not satisfy the Draft 2020-12 schema.");
        exitCode = 1;
    }
    catch (Exception exception) when (exception is IOException or JsonException)
    {
        Console.Error.WriteLine($"Unable to validate '{instancePath}': {exception.Message}");
        exitCode = 1;
    }
}

return exitCode;
