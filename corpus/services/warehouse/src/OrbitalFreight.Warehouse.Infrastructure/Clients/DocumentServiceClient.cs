using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json.Serialization;
using OrbitalFreight.Warehouse.Domain.Abstractions;

namespace OrbitalFreight.Warehouse.Infrastructure.Clients;

/// <summary>
/// Klient document-service. Magazyn wysyła tam wyłącznie materiał dowodowy z hali: zdjęcia
/// uszkodzeń i protokoły rozbieżności inwentaryzacyjnych. Bajtów nigdy nie pobieramy z powrotem —
/// konsola operatorska i aplikacja inspector-android idą po własny link podpisany.
/// </summary>
/// <param name="http">Klient wskazujący na <c>OF_DOCUMENT_BASE_URL</c>.</param>
public sealed class DocumentServiceClient(HttpClient http) : IDocumentPort
{
    private readonly HttpClient _http = http;

    /// <summary>
    /// Wartość <c>owner_type</c> dla naszych dokumentów. Musi istnieć w słowniku
    /// <c>platform.document_owner_types</c> — document-service sprawdza to przed zapisem
    /// i odrzuca wgranie, jeśli wartości tam nie ma.
    /// </summary>
    public const string VarianceOwnerType = "warehouse_count_variance";

    /// <inheritdoc />
    public async Task<string> UploadAsync(
        string ownerType,
        string ownerId,
        string kind,
        string mimeType,
        ReadOnlyMemory<byte> content,
        CancellationToken ct)
    {
        using var form = new MultipartFormDataContent();
        var file = new ByteArrayContent(content.ToArray());
        file.Headers.ContentType = new MediaTypeHeaderValue(mimeType);

        form.Add(new StringContent(ownerType), "owner_type");
        form.Add(new StringContent(ownerId), "owner_id");
        form.Add(new StringContent(kind), "kind");
        form.Add(file, "file", $"{ownerId}.{ExtensionFor(mimeType)}");

        using var response = await _http.PostAsync("/v1/documents", form, ct);
        response.EnsureSuccessStatusCode();

        var dto = await response.Content.ReadFromJsonAsync<DocumentDto>(cancellationToken: ct)
                  ?? throw new InvalidOperationException("document-service returned an empty body");

        // Diament B z §1.2: gdy ten sam plik wgrywa jeszcze jedna usługa, document-service
        // rozpoznaje duplikat po 'documents.sha256' i oddaje istniejące doc_ zamiast zapisywać
        // blob drugi raz. Dla nas oznacza to, że powtórne wysłanie zdjęcia jest bezpieczne.
        return dto.DocumentId;
    }

    /// <inheritdoc />
    public async Task<Uri> CreateSignedUrlAsync(string documentId, CancellationToken ct)
    {
        using var response = await _http.PostAsync($"/v1/documents/{documentId}/signed-url", content: null, ct);
        response.EnsureSuccessStatusCode();

        var dto = await response.Content.ReadFromJsonAsync<SignedUrlDto>(cancellationToken: ct)
                  ?? throw new InvalidOperationException("document-service returned an empty body");

        return new Uri(dto.Url);
    }

    private static string ExtensionFor(string mimeType) => mimeType switch
    {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "application/pdf" => "pdf",
        _ => "bin"
    };

    private sealed record DocumentDto(
        [property: JsonPropertyName("document_id")] string DocumentId,
        [property: JsonPropertyName("sha256")] string Sha256,
        [property: JsonPropertyName("byte_size")] long ByteSize);

    private sealed record SignedUrlDto(
        [property: JsonPropertyName("url")] string Url,
        [property: JsonPropertyName("expires_at")] DateTimeOffset ExpiresAt);
}
