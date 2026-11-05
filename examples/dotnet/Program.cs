var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/", () => Results.Json(new { message = "Hello from the Devsy ACA sandbox!" }));
app.MapGet("/health", () => Results.Json(new { status = "ok" }));

app.Run();
